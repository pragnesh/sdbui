#!/usr/bin/env python3
"""Exercise preferences, keyboard shortcuts, real SQLite browsing and theme rendering."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import time
import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi
from PIL import Image, ImageStat

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--appearance', choices=['Light','Dark'], required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
artifacts = repo / '.build/quality-ui'; artifacts.mkdir(parents=True,exist_ok=True)


def nodes(root=None):
    root = root or Atspi.get_desktop(0)
    yield root
    try:
        for index in range(root.get_child_count()):
            child = root.get_child_at_index(index)
            if child: yield from nodes(child)
    except gi.repository.GLib.Error:
        pass


def find(name, role=None):
    return next((node for node in nodes() if node.get_name()==name and (role is None or node.get_role_name()==role)),None)


def wait(predicate, seconds=20):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        value=predicate()
        if value:return value
        time.sleep(.1)
    raise RuntimeError('Timed out waiting for UI condition')


def click(name):
    node=wait(lambda:find(name,'push button'))
    try: node.get_component_iface().grab_focus()
    except gi.repository.GLib.Error: pass
    assert node.get_action_iface().do_action(0),name
    time.sleep(.2)


x=ctypes.CDLL('libX11.so.6'); xt=ctypes.CDLL('libXtst.so.6')
x.XOpenDisplay.restype=ctypes.c_void_p; display=x.XOpenDisplay(None)
x.XDefaultRootWindow.argtypes=[ctypes.c_void_p];x.XDefaultRootWindow.restype=ctypes.c_ulong
x.XStringToKeysym.argtypes=[ctypes.c_char_p];x.XStringToKeysym.restype=ctypes.c_ulong
x.XKeysymToKeycode.argtypes=[ctypes.c_void_p,ctypes.c_ulong];x.XKeysymToKeycode.restype=ctypes.c_ubyte
x.XFlush.argtypes=[ctypes.c_void_p]
xt.XTestFakeKeyEvent.argtypes=[ctypes.c_void_p,ctypes.c_uint,ctypes.c_int,ctypes.c_ulong]


def key(name, down=True):
    xt.XTestFakeKeyEvent(display,x.XKeysymToKeycode(display,x.XStringToKeysym(name.encode())),int(down),0);x.XFlush(display)


def press(name):key(name);key(name,False)


def shortcut(name):
    key('Control_L');press(name);key('Control_L',False);time.sleep(.2)


def focus_window():
    x.XQueryTree.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.POINTER(ctypes.c_ulong),ctypes.POINTER(ctypes.c_ulong),ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)),ctypes.POINTER(ctypes.c_uint)]
    root=ctypes.c_ulong();parent=ctypes.c_ulong();children=ctypes.POINTER(ctypes.c_ulong)();count=ctypes.c_uint()
    x.XQueryTree(display,x.XDefaultRootWindow(display),ctypes.byref(root),ctypes.byref(parent),ctypes.byref(children),ctypes.byref(count))
    x.XFetchName.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.POINTER(ctypes.c_char_p)]
    x.XSetInputFocus.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_int,ctypes.c_ulong]
    for index in range(count.value):
        title=ctypes.c_char_p();x.XFetchName(display,children[index],ctypes.byref(title))
        if title.value and title.value.decode()=='SDB Query Browser':
            x.XSetInputFocus(display,children[index],1,0);x.XFlush(display);return
    raise RuntimeError('Application X window not found')


def screenshot(path):
    class XImage(ctypes.Structure):
        _fields_=[('width',ctypes.c_int),('height',ctypes.c_int),('xoffset',ctypes.c_int),('format',ctypes.c_int),('data',ctypes.c_void_p),('byte_order',ctypes.c_int),('bitmap_unit',ctypes.c_int),('bitmap_bit_order',ctypes.c_int),('bitmap_pad',ctypes.c_int),('depth',ctypes.c_int),('bytes_per_line',ctypes.c_int),('bits_per_pixel',ctypes.c_int)]
    x.XGetImage.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_int,ctypes.c_int,ctypes.c_uint,ctypes.c_uint,ctypes.c_ulong,ctypes.c_int]
    x.XGetImage.restype=ctypes.POINTER(XImage)
    native=x.XGetImage(display,x.XDefaultRootWindow(display),0,0,1600,1100,0xffffffff,2)
    info=native.contents
    picture=Image.frombytes('RGB',(info.width,info.height),ctypes.string_at(info.data,info.bytes_per_line*info.height),'raw','BGRX',info.bytes_per_line)
    picture.save(path)
    x.XDestroyImage.argtypes=[ctypes.POINTER(XImage)];x.XDestroyImage(native)
    return picture


def has_label(fragment):
    return any(fragment in node.get_name() for node in nodes() if node.get_role_name()=='label')


with tempfile.TemporaryDirectory(prefix='sdbui-quality-ui-') as directory:
    root=Path(directory);config=root/'config';data=root/'data';home=root/'home'
    home.mkdir();profiles=config/'adbc/profiles';profiles.mkdir(parents=True);(data/'sdbui').mkdir(parents=True)
    database=root/'sample.sqlite'
    with sqlite3.connect(database) as db:
        db.execute('CREATE TABLE sample(id INTEGER PRIMARY KEY,value TEXT,nullable TEXT)')
        db.executemany('INSERT INTO sample VALUES (?,?,NULL)',[(i,'long value 雪 '+str(i)+' '+('x'*100)) for i in range(1,301)])
    (profiles/'smoke.toml').write_text('profile_version = 1\ndriver = "sqlite"\n[Options]\nuri = '+json.dumps(str(database))+'\n')
    preferences=data/'sdbui/preferences.json'
    preferences.write_text(json.dumps(dict(pageSize=50,fontSize=17,rowLimit=100,appearance=args.appearance)))
    initial_sql='SELECT id,value,nullable FROM sample ORDER BY id'
    state=dict(version=1,tabs=[dict(favoriteID='smoke',sql=initial_sql,dirty=False,database='main',table=dict(catalog='main',schema='',name='sample'),pane='Query',fontSize=17,sidebarWidth=290)],selectedIndex=0,width=1200,height=800)
    (data/'sdbui/session.json').write_text(json.dumps(state))
    env={key:value for key,value in os.environ.items() if key not in ['SDBUI_SQL','SDBUI_PROFILE','ADBC_PROFILE_PATH','GTK_THEME']}
    env.update(HOME=str(home),XDG_CONFIG_HOME=str(config),XDG_DATA_HOME=str(data),CFFIXED_USER_HOME=str(home),
               ADBC_DRIVER_PATH=os.environ.get('ADBC_DRIVER_PATH',str(repo/'.build/quality-drivers/config/adbc/drivers')),
               SDBUI_APP_ID='dev.sdbui.Quality'+args.appearance,G_DEBUG='fatal-criticals')
    log_path=artifacts/(args.appearance.lower()+'.log')
    with log_path.open('w') as log:
        process=subprocess.Popen([str(repo/'.build/debug/sdbui')],cwd=root,env=env,stdout=log,stderr=log,start_new_session=True)
        try:
            wait(lambda:find('Run All','push button'))
            focus_window();shortcut('l');key('Control_L');press('Return');key('Control_L',False)
            wait(lambda:has_label('100 rows'))
            image=screenshot(artifacts/(args.appearance.lower()+'.png'))
            brightness=sum(ImageStat.Stat(image.crop((320,220,1180,600))).mean)/3
            assert brightness < 110 if args.appearance=='Dark' else brightness > 170,(args.appearance,brightness)
            shortcut('comma');wait(lambda:find('Apply preferences','push button'))
            click('Reset defaults');click('Apply preferences')
            wait(lambda:json.loads(preferences.read_text())['fontSize']==13)
            saved=json.loads(preferences.read_text())
            assert saved==dict(pageSize=1000,fontSize=13,rowLimit=10000,appearance='System'),saved
            shortcut('l');key('Control_L');press('Return');key('Control_L',False)
            wait(lambda:has_label('300 rows'))
            click('Show rows')
            wait(lambda:has_label('1–300'))
            restored=screenshot(artifacts/(args.appearance.lower()+'-system.png'))
            brightness=sum(ImageStat.Stat(restored.crop((320,220,1180,600))).mean)/3
            assert brightness>170,('System theme did not return to light',brightness)
            shortcut('comma');wait(lambda:find('Cancel preferences','push button'));press('Escape')
            wait(lambda:not find('Apply preferences','push button'))
            assert process.poll() is None,log_path.read_text()
            print(args.appearance+': real SQLite query, preferences persistence, Ctrl+Enter, table paging, shortcuts and rendered theme passed')
        except Exception:
            screenshot(artifacts/(args.appearance.lower()+'-failure.png'))
            print([(node.get_role_name(),node.get_name()) for node in nodes()][-100:])
            print(log_path.read_text())
            raise
        finally:
            try:os.killpg(process.pid,signal.SIGTERM)
            except ProcessLookupError:pass
            try:process.wait(timeout=10)
            except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait()
