"""xmodem_send.py - XMODEM-CRC sender for SPI flash programming (Windows side).
Uses pyserial for reliable high-speed serial I/O.
Run via: python312\\python.exe xmodem_send.py COM7 start_board.bin
"""
import sys, time, struct

def crc16_ccitt(data):
    crc = 0
    for b in data:
        crc ^= (b << 8)
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if (crc & 0x8000) else (crc << 1) & 0xFFFF
    return crc

def main():
    com_port = sys.argv[1]
    filepath = sys.argv[2]
    baud = 230400
    import serial
    ser = serial.Serial(com_port, baud, timeout=30.0, write_timeout=3.0)
    print(f"[xmodem] Opened {com_port} @ {baud}")

    # Drain startup output
    print("[xmodem] Draining programmer output (2s) ...")
    time.sleep(2.0)
    raw = ser.read(ser.in_waiting)
    if raw:
        try: print(f"[xmodem] Programmer says: {raw.decode('ascii', errors='replace')}")
        except: print(f"[xmodem] Programmer raw: {raw.hex()}")

    # Send 'x' to start xmodem
    print("[xmodem] Sending 'x' ...")
    ser.write(b'x')
    time.sleep(0.5)

    # Read file
    with open(filepath, 'rb') as f:
        data = f.read()
    print(f"[xmodem] File: {filepath} ({len(data)} bytes)")

    # Wait for 'C' (CRC mode)
    print("[xmodem] Waiting for C (CRC handshake) ...")
    got_c = False
    deadline = time.time() + 15
    while time.time() < deadline:
        b = ser.read(1)
        if b == b'C':
            got_c = True
            break
        elif b == b'\x15':  # NAK = checksum mode
            print("[xmodem] Got NAK - checksum mode (will use CRC anyway)")
            got_c = True
            break
    if not got_c:
        print("[xmodem] ERROR: no handshake")
        ser.close()
        sys.exit(1)
    print("[xmodem] Got C - CRC-16 mode")

    # Send blocks — 128-byte (SOH) XMODEM-CRC
    SOH, EOT, ACK, NAK, CAN = 0x01, 0x04, 0x06, 0x15, 0x18
    BLK_SIZE = 128
    total_blocks = (len(data) + BLK_SIZE - 1) // BLK_SIZE
    for blk_idx in range(total_blocks):
        seq = blk_idx + 1
        chunk = data[blk_idx*BLK_SIZE : (blk_idx+1)*BLK_SIZE].ljust(BLK_SIZE, b'\x00')
        crc = crc16_ccitt(chunk)
        pkt = bytes([SOH, seq & 0xFF, 0xFF - (seq & 0xFF)]) + chunk + struct.pack('>H', crc)
        naits = 0
        while True:
            ser.reset_input_buffer()  # clear any stale NAKs from buffer
            ser.write(pkt)
            ser.flush()
            resp = ser.read(1)  # 30s timeout — patient wait for flash erase
            if resp == bytes([ACK]):
                if seq % 200 == 0 or seq <= 3 or seq >= total_blocks - 2:
                    print(f"[xmodem] Block {seq}/{total_blocks}")
                time.sleep(0.06)  # pace to ~2KB/s like SecureCRT
                break
            elif resp in (bytes([NAK]), b'C'):
                naits += 1
                if naits <= 3 or naits % 10 == 0:
                    print(f"[xmodem] Block {seq} NAK {naits}/50")
                if naits >= 50:
                    print(f"[xmodem] ERROR: block {seq} failed")
                    ser.write(bytes([CAN, CAN])); ser.close(); sys.exit(1)
            elif resp == bytes([CAN]):
                print("[xmodem] ERROR: receiver CAN"); ser.close(); sys.exit(1)
            # timeout (empty) or non-protocol byte: loop resends with fresh 30s wait

    # Send EOT
    print("[xmodem] Sending EOT ...")
    for _ in range(5):
        ser.write(bytes([EOT]))
        resp = ser.read(1)
        if resp == bytes([ACK]):
            break
        time.sleep(0.5)

    time.sleep(1.0)
    remaining = ser.read(ser.in_waiting)
    if remaining:
        try: print(f"[xmodem] Final: {remaining.decode('ascii', errors='replace')}")
        except: pass

    ser.close()
    print("[xmodem] Done - SPI flash programmed")
    print("XMODEM_OK")

if __name__ == '__main__':
    main()
