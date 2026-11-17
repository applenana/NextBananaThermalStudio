import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Use the existing libserialport handle; never open the COM port a second time.
void configureWindowsRxBuffer(int portAddress) {
  if (!Platform.isWindows) return;
  final serial = DynamicLibrary.open('serialport.dll');
  final getHandle = serial
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<IntPtr>),
        int Function(Pointer<Void>, Pointer<IntPtr>)
      >('sp_get_port_handle');
  final setup = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        Int32 Function(IntPtr, Uint32, Uint32),
        int Function(int, int, int)
      >('SetupComm');
  final handle = calloc<IntPtr>();
  try {
    if (getHandle(Pointer<Void>.fromAddress(portAddress), handle) == 0 &&
        handle.value != 0) {
      // Advisory queue sizing; drivers may choose a different actual capacity.
      setup(handle.value, 256 * 1024, 16 * 1024);
    }
  } finally {
    calloc.free(handle);
  }
}
