#!/usr/bin/env python3
"""
inject_dylib.py — Inject a dylib into a Mach-O binary by adding LC_LOAD_DYLIB.
Also copies the dylib into the app's Frameworks/ directory.

Usage:
    python inject_dylib.py <path_to_IPA_or_app> <dylib_file>

Example:
    python inject_dylib.py C:/rev/MAX_app/Payload/MAX.app/MAX MAXMods.dylib
"""

import struct
import sys
import os
import shutil

# Mach-O constants
MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB = 0x0C
LC_ID_DYLIB = 0x0D

def read_u32(data, offset):
    return struct.unpack_from('<I', data, offset)[0]

def write_u32(data, offset, value):
    struct.pack_into('<I', data, offset, value)

def align(value, alignment):
    return (value + alignment - 1) & ~(alignment - 1)

def inject_dylib(binary_path, dylib_name):
    """Add LC_LOAD_DYLIB command to Mach-O binary."""

    with open(binary_path, 'rb') as f:
        data = bytearray(f.read())

    # Verify Mach-O magic
    magic = read_u32(data, 0)
    if magic != MH_MAGIC_64:
        print(f"ERROR: Not a 64-bit Mach-O file (magic: 0x{magic:08X})")
        return False

    # Read header
    ncmds = read_u32(data, 16)        # number of load commands
    sizeofcmds = read_u32(data, 20)   # size of load commands

    # Build the LC_LOAD_DYLIB command
    dylib_path = f"@executable_path/Frameworks/{dylib_name}"
    dylib_path_bytes = dylib_path.encode('utf-8') + b'\x00'

    # LC_LOAD_DYLIB structure:
    #   uint32_t cmd (LC_LOAD_DYLIB)
    #   uint32_t cmdsize
    #   uint32_t name_offset (offset to string from start of command)
    #   uint32_t timestamp
    #   uint32_t current_version
    #   uint32_t compat_version
    #   char[] name (null-terminated, padded to 4-byte alignment)

    name_offset = 24  # 6 * uint32
    cmdsize = align(name_offset + len(dylib_path_bytes), 8)

    new_cmd = bytearray(cmdsize)
    struct.pack_into('<I', new_cmd, 0, LC_LOAD_DYLIB)      # cmd
    struct.pack_into('<I', new_cmd, 4, cmdsize)             # cmdsize
    struct.pack_into('<I', new_cmd, 8, name_offset)         # name offset
    struct.pack_into('<I', new_cmd, 12, 2)                  # timestamp
    struct.pack_into('<I', new_cmd, 16, 0x00010000)         # current_version 1.0.0
    struct.pack_into('<I', new_cmd, 20, 0x00010000)         # compat_version 1.0.0
    new_cmd[name_offset:name_offset+len(dylib_path_bytes)] = dylib_path_bytes

    # Check if this dylib is already loaded
    header_size = 32  # mach_header_64 size
    offset = header_size
    for i in range(ncmds):
        cmd = read_u32(data, offset)
        cmd_size = read_u32(data, offset + 4)
        if cmd == LC_LOAD_DYLIB:
            name_off = read_u32(data, offset + 8)
            name_end = data.index(b'\x00', offset + name_off)
            existing_name = data[offset + name_off:name_end].decode('utf-8')
            if dylib_name in existing_name:
                print(f"SKIP: {dylib_name} is already loaded in this binary")
                return True
        offset += cmd_size

    # Insert new load command at the end of existing commands
    insert_offset = header_size + sizeofcmds

    # Check if there's enough space (padding/zero bytes after commands)
    space_needed = cmdsize
    available = 0
    for i in range(insert_offset, insert_offset + space_needed + 256):
        if i >= len(data) or data[i] != 0:
            break
        available += 1

    if available < space_needed:
        print(f"ERROR: Not enough space for new load command")
        print(f"  Need {space_needed} bytes, only {available} zero bytes available")
        print(f"  Try using insert_dylib tool or LIEF library instead")
        return False

    # Write the new command
    data[insert_offset:insert_offset+cmdsize] = new_cmd

    # Update header: ncmds + 1, sizeofcmds + cmdsize
    write_u32(data, 16, ncmds + 1)
    write_u32(data, 20, sizeofcmds + cmdsize)

    # Write back
    with open(binary_path, 'wb') as f:
        f.write(data)

    print(f"OK: Injected {dylib_path} into {os.path.basename(binary_path)}")
    print(f"  Load commands: {ncmds} -> {ncmds + 1}")
    print(f"  Commands size: {sizeofcmds} -> {sizeofcmds + cmdsize}")
    return True


def main():
    if len(sys.argv) < 3:
        print("Usage: python inject_dylib.py <mach-o binary> <dylib file>")
        print("")
        print("Example:")
        print("  python inject_dylib.py MAX.app/MAX MAXMods.dylib")
        sys.exit(1)

    binary_path = sys.argv[1]
    dylib_file = sys.argv[2]

    if not os.path.exists(binary_path):
        print(f"ERROR: Binary not found: {binary_path}")
        sys.exit(1)

    if not os.path.exists(dylib_file):
        print(f"ERROR: Dylib not found: {dylib_file}")
        sys.exit(1)

    dylib_name = os.path.basename(dylib_file)

    # Copy dylib to Frameworks/
    app_dir = os.path.dirname(binary_path)
    frameworks_dir = os.path.join(app_dir, "Frameworks")
    os.makedirs(frameworks_dir, exist_ok=True)
    dest = os.path.join(frameworks_dir, dylib_name)
    shutil.copy2(dylib_file, dest)
    print(f"Copied {dylib_name} -> {frameworks_dir}/")

    # Inject load command
    if inject_dylib(binary_path, dylib_name):
        print("")
        print("Done! Now re-sign the IPA with ESign or ldid.")
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
