#!/usr/bin/env python3
"""Format/parser regressions. Run with the private transfer Python runtime."""
import ctypes
import decimal
import json
from pathlib import Path
import tempfile
import unittest
import pyarrow as pa
import pyarrow.ipc as ipc
import pyarrow.parquet as pq

class Stream(ctypes.Structure):
    _fields_ = [(name, ctypes.c_void_p) for name in ('get_schema', 'get_next', 'get_last_error', 'release', 'private_data')]

poll = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p)(lambda _: int(cancelled))
progress = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_int64)(lambda _, n: None)
cancelled = False
config = {'site': str(Path(pa.__file__).parent.parent), 'poll': ctypes.cast(poll, ctypes.c_void_p).value,
          'progress': ctypes.cast(progress, ctypes.c_void_p).value, 'token': 0}
source = (Path(__file__).resolve().parents[1] / 'Sources/ADBCKit/Resources/transfer.py').read_text()
namespace = {'_sdbui_config_json': json.dumps(config)}
exec(source[:source.rindex('\ncheck_cancelled()')], namespace)

class TransferTests(unittest.TestCase):
    def setUp(self):
        global cancelled
        cancelled = False
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
    def records(self, text):
        path = self.root / 'input.csv'
        path.write_text(text, newline='')
        return list(namespace['csv_records'](path, ','))
    def test_csv_quotes_nulls_bom_and_multiline(self):
        self.assertEqual(self.records('\ufeffa,b\r\n"x\r\ny","he said ""yes"""\r\n\\N,"\\N"\r\n,""\r\n'), [
            [('a', False), ('b', False)], [('x\r\ny', True), ('he said "yes"', True)],
            [('\\N', False), ('\\N', True)], [('', False), ('', True)]])
        value = namespace['csv_value']
        opts = {'nullMarker': '\\N', 'emptyIsNull': True}
        self.assertIsNone(value(('\\N', False), opts))
        self.assertEqual(value(('\\N', True), opts), '\\N')
        self.assertIsNone(value(('', False), opts))
        self.assertEqual(value(('', True), opts), '')
    def test_invalid_csv(self):
        for text in ['"unterminated', 'ab"cd,ef', '"abc"junk,ef']:
            with self.assertRaises(ValueError): self.records(text)
    def table(self):
        return pa.table({'id': pa.array([2**60, None], type=pa.int64()),
                         'amount': pa.array([decimal.Decimal('12345678901234.123456'), None], type=pa.decimal128(30, 6)),
                         'text': ['a,"b"\n雪', '\\N'], 'binary': [bytes(range(256)), None]})
    def export(self, table, fmt, name='out'):
        reader = pa.RecordBatchReader.from_batches(table.schema, table.to_batches(max_chunksize=1))
        stream = Stream(); reader._export_to_c(ctypes.addressof(stream))
        destination = self.root / (name + '.' + fmt)
        namespace['export']({'stream': ctypes.addressof(stream), 'path': str(destination), 'format': fmt,
                             'dialect': 'postgres', 'tableSQL': '"public"."example"'})
        return destination
    def test_typed_arrow_and_parquet(self):
        table = self.table()
        arrow = self.export(table, 'arrow')
        self.assertTrue(ipc.open_file(arrow).read_all().equals(table))
        parquet = self.export(table, 'parquet')
        self.assertTrue(pq.read_table(parquet).equals(table))
    def test_json_and_csv_full_values(self):
        table = self.table()
        values = json.loads(self.export(table, 'json').read_text(), parse_float=decimal.Decimal)
        self.assertEqual(values[0]['amount'], decimal.Decimal('12345678901234.123456'))
        self.assertEqual(values[0]['id'], 2**60)
        self.assertEqual(values[0]['binary'], '\\x' + bytes(range(256)).hex())
        records = list(namespace['csv_records'](self.export(table, 'csv'), ','))
        self.assertEqual(records[1][2], ('a,"b"\n雪', True))
        self.assertEqual(records[2][0], ('\\N', False))
        self.assertEqual(records[2][2], ('\\N', True))
    def test_atomic_failure_preserves_file(self):
        global cancelled
        destination = self.root / 'out.parquet'; destination.write_bytes(b'existing')
        cancelled = True
        with self.assertRaises(RuntimeError): self.export(self.table(), 'parquet')
        self.assertEqual(destination.read_bytes(), b'existing')
        self.assertEqual(list(self.root.glob('.sdbui-export-*')), [])
    def test_conversion(self):
        convert = namespace['convert_column']
        self.assertEqual(convert(['42', None], pa.int64()).to_pylist(), [42, None])
        self.assertEqual(convert(['\\x00ff', None], pa.binary()).to_pylist(), [b'\x00\xff', None])
        with self.assertRaises(Exception): convert(['not a number'], pa.int64())
    def import_reader(self, path, schema, mapping):
        options = {'delimiter': ',', 'header': True, 'nullMarker': '\\N', 'emptyIsNull': False}
        schema_reader = pa.RecordBatchReader.from_batches(schema, [])
        schema_stream, output_stream = Stream(), Stream()
        schema_reader._export_to_c(ctypes.addressof(schema_stream))
        namespace['csv_reader']({'path': str(path), 'options': options,
            'fingerprint': namespace['fingerprint'](path), 'schema': __import__('base64').b64encode(schema.serialize().to_pybytes()).decode(),
            'schemaStream': ctypes.addressof(schema_stream), 'outputStream': ctypes.addressof(output_stream), 'mapping': mapping})
        return pa.RecordBatchReader._import_from_c(ctypes.addressof(output_stream))
    def test_import_batches_and_precise_types(self):
        path = self.root / 'input.csv'
        path.write_text('ignored,number,amount,time\n' + ''.join(f'skip,{i},12345678901234.123456,2025-02-03 04:05:06.123456\n' for i in range(2001)))
        schema = pa.schema([('number', pa.int64()), ('amount', pa.decimal128(30,6)), ('time', pa.timestamp('us'))])
        with self.import_reader(path, schema, [None, 'number', 'amount', 'time']) as reader:
            batches = list(reader)
        self.assertEqual([batch.num_rows for batch in batches], [1000, 1000, 1])
        self.assertEqual(batches[0].column(1)[0].as_py(), decimal.Decimal('12345678901234.123456'))
        self.assertEqual(str(batches[0].column(2)[0]), '2025-02-03 04:05:06.123456')
    def test_import_detects_changes_and_late_bad_rows(self):
        path = self.root / 'input.csv'; schema = pa.schema([('number', pa.int64())])
        path.write_text('number\n' + '1\n' * 2001)
        with self.import_reader(path, schema, ['number']) as reader:
            self.assertEqual(reader.read_next_batch().num_rows, 1000)
            path.write_text('number\n2\n')
            with self.assertRaises(Exception): reader.read_all()
        path.write_text('number\n' + '1\n' * 2000 + 'invalid\n')
        with self.import_reader(path, schema, ['number']) as reader:
            self.assertEqual(reader.read_next_batch().num_rows, 1000)
            with self.assertRaises(Exception): reader.read_all()
    def test_empty_exports(self):
        table = self.table().slice(0, 0)
        self.assertEqual(json.loads(self.export(table, 'json').read_text()), [])
        self.assertEqual(ipc.open_file(self.export(table, 'arrow')).read_all().num_rows, 0)
        self.assertEqual(pq.read_table(self.export(table, 'parquet')).num_rows, 0)

if __name__ == '__main__': unittest.main()
