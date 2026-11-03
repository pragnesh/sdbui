"""Trusted in-process transfer helper. Only JSON configuration crosses the bridge."""
import base64
import ctypes
import datetime
import decimal
import json
import math
import os
from pathlib import Path
import stat
import sys
import tempfile
import uuid

_config = json.loads(_sdbui_config_json)
if _config['site'] not in sys.path:
    sys.path.insert(0, _config['site'])
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.ipc as ipc
import pyarrow.parquet as pq

_poll = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p)(int(_config['poll']))
_progress = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_int64)(int(_config['progress']))
_token = int(_config['token'])

def check_cancelled():
    if _poll(_token):
        raise RuntimeError('Transfer cancelled.')

def progress(count):
    check_cancelled()
    _progress(_token, count)

def fingerprint(path):
    info = os.stat(path)
    if not stat.S_ISREG(info.st_mode):
        raise ValueError('Choose a regular UTF-8 CSV file.')
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]

def csv_records(path, delimiter):
    """RFC 4180 records, retaining quoting to distinguish NULL from a literal marker."""
    if delimiter not in [',', ';', '\t', '|']:
        raise ValueError('Unsupported CSV delimiter.')
    with open(path, 'r', encoding='utf-8-sig', newline='') as source:
        row, chars = [], []
        quoted = inside = after_quote = skip_lf = False
        size = 0
        def field():
            nonlocal chars, quoted, after_quote, size
            result = (''.join(chars), quoted)
            chars, quoted, after_quote, size = [], False, False, 0
            return result
        while chunk := source.read(65536):
            check_cancelled()
            for char in chunk:
                if skip_lf:
                    skip_lf = False
                    if char == '\n':
                        continue
                if inside:
                    if char == '"':
                        inside, after_quote = False, True
                    else:
                        chars.append(char); size += 1
                elif after_quote and char == '"':
                    chars.append('"'); size += 1
                    inside, after_quote = True, False
                elif char == delimiter:
                    row.append(field())
                elif char in '\r\n':
                    row.append(field())
                    if not (len(row) == 1 and row[0] == ('', False)):
                        yield row
                    row = []
                    skip_lf = char == '\r'
                elif after_quote:
                    raise ValueError('Unexpected characters after a closing CSV quote.')
                elif char == '"':
                    if chars:
                        raise ValueError('A quote inside an unquoted CSV field must be escaped.')
                    quoted = inside = True
                else:
                    chars.append(char); size += 1
                if size > 64 * 1024 * 1024:
                    raise ValueError('A CSV field exceeds the 64 million character field limit.')
        if inside:
            raise ValueError('Unterminated quoted CSV field.')
        if row or chars or quoted or after_quote:
            row.append(field())
            yield row

def csv_header(path, options):
    records = csv_records(path, options['delimiter'])
    try:
        first = next(records)
    except StopIteration:
        raise ValueError('The CSV file is empty.')
    finally:
        records.close()
    if options['header']:
        return [value for value, _ in first]
    return [f'Column {i + 1}' for i in range(len(first))]

def csv_value(cell, options):
    value, quoted = cell
    if not quoted and (value == options['nullMarker'] or (options['emptyIsNull'] and value == '')):
        return None
    return value

def scalar_text(scalar):
    typ = scalar.type
    if pa.types.is_timestamp(typ) or pa.types.is_date(typ) or pa.types.is_time(typ) or pa.types.is_duration(typ):
        return scalar.cast(pa.string()).as_py()
    value = scalar.as_py()
    if isinstance(value, bytes):
        return '\\x' + value.hex()
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, decimal.Decimal):
        return format(value, 'f')
    if isinstance(value, (datetime.datetime, datetime.date, datetime.time, uuid.UUID)):
        return str(value)
    if isinstance(value, (list, tuple, dict)):
        return json_scalar(scalar)
    return str(value)

def json_scalar(scalar):
    if not scalar.is_valid:
        return 'null'
    typ = scalar.type
    if pa.types.is_dictionary(typ):
        return json_scalar(scalar.value)
    if pa.types.is_struct(typ):
        return '{' + ','.join(json.dumps(field.name, ensure_ascii=False) + ':' + json_scalar(scalar[i]) for i, field in enumerate(typ)) + '}'
    if pa.types.is_map(typ):
        return '[' + ','.join('{"key":' + json_scalar(entry[0]) + ',"value":' + json_scalar(entry[1]) + '}' for entry in scalar.values) + ']'
    if pa.types.is_list(typ) or pa.types.is_large_list(typ) or pa.types.is_fixed_size_list(typ):
        return '[' + ','.join(json_scalar(value) for value in scalar.values) + ']'
    value = scalar.as_py() if not (pa.types.is_timestamp(typ) or pa.types.is_date(typ) or pa.types.is_time(typ)) else scalar_text(scalar)
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, int):
        return str(value)
    if isinstance(value, decimal.Decimal) and value.is_finite():
        return format(value, 'f')
    if isinstance(value, float) and math.isfinite(value):
        return repr(value)
    return json.dumps(scalar_text(scalar), ensure_ascii=False)

def csv_quote(value):
    return '"' + value.replace('"', '""') + '"'

def sql_string(value, dialect):
    if dialect == 'mysql':
        return "_utf8mb4 X'" + value.encode('utf-8').hex() + "'"
    if '\0' in value:
        raise ValueError('SQL text values cannot contain NUL. Use Arrow or Parquet for this column.')
    return ("E'" if dialect == 'postgres' else "'") + value.replace('\\', '\\\\' if dialect == 'postgres' else '\\').replace("'", "''") + "'"

def identifier(value, dialect):
    quote = '`' if dialect == 'mysql' else '"'
    return quote + value.replace(quote, quote * 2) + quote

def sql_scalar(scalar, config, column):
    if not scalar.is_valid:
        return 'NULL'
    if config.get('sqlText', False):
        text = scalar.as_py()
        if config['dialect'] == 'mysql' and column in config.get('sqlBinary', []):
            return "X'" + text + "'"
        return sql_string(text, config['dialect'])
    value = scalar.as_py()
    if isinstance(value, bool):
        return 'TRUE' if value else 'FALSE'
    if isinstance(value, (int, decimal.Decimal)):
        return str(value)
    if isinstance(value, float):
        if not math.isfinite(value):
            if config['dialect'] != 'postgres':
                raise ValueError('Non-finite floats require Arrow or Parquet for this dialect.')
            return sql_string(str(value), config['dialect'])
        return repr(value)
    if isinstance(value, bytes):
        return ("decode('" + value.hex() + "','hex')") if config['dialect'] == 'postgres' else "X'" + value.hex() + "'"
    if isinstance(value, (list, dict, tuple)):
        raise ValueError('SQL export of this nested type is not supported by the driver.')
    return sql_string(scalar_text(scalar), config['dialect'])

def export(config):
    destination = Path(config['path'])
    reader = pa.RecordBatchReader._import_from_c(int(config['stream']))
    temporary = None
    rows = 0
    try:
        fd, temporary = tempfile.mkstemp(prefix='.sdbui-export-', dir=destination.parent)
        os.fchmod(fd, 0o600); os.close(fd)
        schema = reader.schema
        names = schema.names
        if config['format'] == 'json' and len(set(names)) != len(names):
            raise ValueError('JSON export requires unique column names.')
        if config['format'] in ('arrow', 'parquet'):
            with (ipc.new_file(temporary, schema) if config['format'] == 'arrow' else pq.ParquetWriter(temporary, schema)) as writer:
                for batch in reader:
                    check_cancelled()
                    writer.write_batch(batch)
                    rows += batch.num_rows; progress(batch.num_rows)
        else:
            with open(temporary, 'w', encoding='utf-8', newline='') as output:
                first = True
                if config['format'] == 'csv':
                    output.write(','.join(csv_quote(name) for name in names) + '\r\n')
                elif config['format'] == 'json':
                    output.write('[')
                for batch in reader:
                    check_cancelled()
                    for row in range(batch.num_rows):
                        if row % 1000 == 0: check_cancelled()
                        values = [column[row] for column in batch.columns]
                        if config['format'] == 'csv':
                            output.write(','.join('\\N' if not value.is_valid else csv_quote(scalar_text(value)) for value in values) + '\r\n')
                        elif config['format'] == 'json':
                            if not first:
                                output.write(',\n')
                            output.write('{' + ','.join(json.dumps(name, ensure_ascii=False) + ':' + json_scalar(value) for name, value in zip(names, values)) + '}')
                            first = False
                        else:
                            selected = [i for i, name in enumerate(names) if name not in config.get('skip', [])]
                            if not selected:
                                output.write('INSERT INTO ' + config['tableSQL'] + (' () VALUES ();\n' if config['dialect'] == 'mysql' else ' DEFAULT VALUES;\n'))
                            else:
                                columns = ', '.join(identifier(names[i], config['dialect']) for i in selected)
                                override = ' OVERRIDING SYSTEM VALUE' if config.get('identity') and config['dialect'] == 'postgres' else ''
                                output.write('INSERT INTO ' + config['tableSQL'] + ' (' + columns + ')' + override + ' VALUES (' + ', '.join(sql_scalar(values[i], config, names[i]) for i in selected) + ');\n')
                        rows += 1
                    progress(batch.num_rows)
                if config['format'] == 'json':
                    output.write(']\n')
                output.flush(); os.fsync(output.fileno())
        reader.close()
        check_cancelled()
        with open(temporary, 'rb') as complete:
            os.fsync(complete.fileno())
        os.replace(temporary, destination)
        temporary = None
        return {'rows': rows}
    finally:
        reader.close()
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass

def read_schema(address):
    with pa.RecordBatchReader._import_from_c(int(address)) as reader:
        return reader.schema

def preview(config):
    path, options = config['path'], config['options']
    before = fingerprint(path)
    headers = csv_header(path, options)
    records = csv_records(path, options['delimiter'])
    if options['header']:
        next(records, None)
    samples = []
    try:
        for record in records:
            if len(record) != len(headers):
                raise ValueError('CSV row width does not match the header.')
            samples.append([None if (value := csv_value(cell, options)) is None else value[:2000] for cell in record])
            if len(samples) == 20:
                break
    finally:
        records.close()
    if fingerprint(path) != before:
        raise ValueError('The CSV changed during preview. Preview it again.')
    schema = read_schema(config['schemaStream'])
    return {'headers': headers, 'samples': samples, 'fingerprint': before,
            'schema': base64.b64encode(schema.serialize().to_pybytes()).decode('ascii')}

def convert_column(values, typ):
    if hasattr(typ, 'extension_name') and getattr(typ, 'extension_name', '') == 'arrow.uuid':
        storage = pa.array([uuid.UUID(value).bytes if value is not None else None for value in values], type=typ.storage_type)
        return pa.ExtensionArray.from_storage(typ, storage)
    if hasattr(typ, 'storage_type'):
        return pa.ExtensionArray.from_storage(typ, convert_column(values, typ.storage_type))
    if pa.types.is_binary(typ) or pa.types.is_large_binary(typ) or pa.types.is_fixed_size_binary(typ):
        decoded = []
        for value in values:
            if value is None:
                decoded.append(None)
            elif value.startswith('\\x'):
                decoded.append(bytes.fromhex(value[2:]))
            else:
                raise ValueError('Binary CSV values must use \\x-prefixed hexadecimal text.')
        return pa.array(decoded, type=typ)
    array = pa.array(values, type=pa.string())
    if pa.types.is_dictionary(typ):
        return array.dictionary_encode().cast(typ)
    return pc.cast(array, typ, safe=True)

def csv_reader(config):
    global _sdbui_reader
    path, options = config['path'], config['options']
    if fingerprint(path) != config['fingerprint']:
        raise ValueError('The CSV changed after preview. Preview it again.')
    actual = read_schema(config['schemaStream'])
    expected = ipc.read_schema(pa.BufferReader(base64.b64decode(config['schema'])))
    if not actual.equals(expected, check_metadata=True):
        raise ValueError('The target schema changed after preview. Preview it again.')
    mapping = config['mapping']
    used = [name for name in mapping if name is not None]
    if not used or len(set(used)) != len(used):
        raise ValueError('Map at least one column, without duplicate target columns.')
    indices = [i for i, name in enumerate(mapping) if name is not None]
    schema = pa.schema([actual.field(mapping[i]) for i in indices])
    records = csv_records(path, options['delimiter'])
    if options['header']:
        next(records, None)
    def batches():
        cells, size = [], 0
        def make_batch(rows):
            columns = []
            for i, field in zip(indices, schema):
                try:
                    columns.append(convert_column([csv_value(row[i], options) for row in rows], field.type))
                except Exception as error:
                    raise ValueError(f'Column {field.name}: {error}') from error
            return pa.RecordBatch.from_arrays(columns, schema=schema)
        try:
            for record in records:
                check_cancelled()
                if len(record) != len(mapping):
                    raise ValueError('CSV row width does not match the preview.')
                cells.append(record); size += sum(len(cell[0]) for cell in record)
                if len(cells) >= 1000 or size >= 8 * 1024 * 1024:
                    batch = make_batch(cells); progress(batch.num_rows)
                    yield batch
                    cells, size = [], 0
            if cells:
                batch = make_batch(cells); progress(batch.num_rows)
                yield batch
            if fingerprint(path) != config['fingerprint']:
                raise ValueError('The CSV changed while importing. Import rolled back.')
        finally:
            records.close()
    _sdbui_reader = pa.RecordBatchReader.from_batches(schema, batches())
    _sdbui_reader._export_to_c(int(config['outputStream']))
    return {'ready': True}

check_cancelled()
if _config['mode'] == 'export':
    _result = export(_config)
elif _config['mode'] == 'preview':
    _result = preview(_config)
elif _config['mode'] == 'reader':
    _result = csv_reader(_config)
else:
    raise ValueError('Unknown transfer operation.')
_sdbui_result_json = json.dumps(_result, ensure_ascii=False)
