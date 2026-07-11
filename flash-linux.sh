#!/usr/bin/env bash
# flash-linux.sh — 烧 Linux SoC bitstream + JTAG 直载内核镜像,板上启动 Linux。
# 经 WSL 调 Windows 版 Vivado(板子接在 Windows 上),风格/握手同 flash-board.sh。
#
# 启动路线 A(SPI-XIP stub + JTAG 直载):复位 stub 已一次性烧在 SPI flash
# (0x1c000000 XIP,烧法见 scripts/flash-spi-stub.sh + scripts/board/flash_spi_stub.md)。
# 本脚本日常只做:
#   [烧 bit] → 压软复位 → vmlinux.bin@0x00300000 + param_5f.bin@0x05f00000
#   → 内核入口写 mailbox 0x05f000a0 → 放复位 → stub 读 mailbox jirl 进内核。
# 内核重编 / 换 cmdline 都不用重烧 flash。
# --stub: 退回路线C(同时 JTAG 载 stub 到 DDR,不需预烧 SPI flash)。
#
# 用法:
#   ./scripts/flash-linux.sh [BITSTREAM]     # 缺省先找 board/linux_soc 综合产物,
#                                            #   再 fallback synth/results/*_soc/soc_top.bit
#   ./scripts/flash-linux.sh --no-bit        # 不重烧 bit,只重载镜像 + 复位重启
#   ./scripts/flash-linux.sh --images DIR    # 镜像目录,缺省 .linux_bringup/board_images
#                                            #   (需含 vmlinux.bin / param_5f.bin / entry.txt)
#   ./scripts/flash-linux.sh --cmdline "..." # 用给定 cmdline 现场重生成 param_5f.bin
#                                            #   (写临时文件,不动 --images 目录原件)
#
# 一次性配置(同 flash-board.sh):在 ~/.bashrc 里指向你的 Windows Vivado,例如
#   export VIVADO_WIN_BAT='C:\Xilinx\Vivado\2023.2\bin\vivado.bat'
# 详见 README「## 上板烧录」。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${VIVADO_WIN_BAT:?未设置 VIVADO_WIN_BAT(你的 Windows vivado.bat 路径)— 见 README 上板烧录}"
SCRATCH="${VIVADO_WSL_SCRATCH:-/mnt/c/Users/Public/vivado-wsl}"   # cmd.exe 不能用 \\wsl UNC 当 cwd,需 C: 盘暂存区
CMD="${WIN_CMD:-/mnt/c/Windows/System32/cmd.exe}"
BIT=""; NO_BIT=0; IMG_DIR="$REPO/.linux_bringup/board_images"; CMDLINE=""; LOAD_STUB=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-bit)  NO_BIT=1; shift ;;
    --stub)    LOAD_STUB=1; shift ;;     # 路线C fallback:同时 JTAG 载 stub 到 DDR
    --images)  IMG_DIR="${2:?--images 需要一个目录}"; shift 2 ;;
    --cmdline) CMDLINE="${2:?--cmdline 需要一个字符串}"; shift 2 ;;
    -h|--help) sed -n '2,23p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) BIT="$1"; shift ;;
  esac
done
if [ "$NO_BIT" -eq 1 ] && [ -n "$BIT" ]; then echo "[flash-linux] ★ --no-bit 和 BITSTREAM 参数互斥"; exit 1; fi

# ---------- 镜像校验(vmlinux.bin + entry.txt 必须在;param 可被 --cmdline 现场生成) ----------
VMLINUX="$IMG_DIR/vmlinux.bin"
PARAM="$IMG_DIR/param_5f.bin"
ENTRY_TXT="$IMG_DIR/entry.txt"
STUB="$IMG_DIR/start_board.bin"
[ -f "$VMLINUX" ] || { echo "[flash-linux] ★ 缺 $VMLINUX — 先跑 ./scripts/linux_bringup/board/gen-boot-images.sh 生成板上镜像"; exit 1; }
[ -f "$ENTRY_TXT" ] || { echo "[flash-linux] ★ 缺 $ENTRY_TXT(内核入口,readelf -h vmlinux 的 Entry point)"; exit 1; }
if [ "$LOAD_STUB" -eq 1 ]; then
  [ -f "$STUB" ] || { echo "[flash-linux] ★ --stub 模式缺 $STUB — 先跑 gen-boot-images.sh"; exit 1; }
fi

ENTRY="$(tr -d ' \t\r\n' < "$ENTRY_TXT")"
ENTRY="${ENTRY#0x}"; ENTRY="${ENTRY#0X}"
[[ "$ENTRY" =~ ^[0-9a-fA-F]{1,8}$ ]] || { echo "[flash-linux] ★ entry.txt 内容非法(要 32-bit hex): $(cat "$ENTRY_TXT")"; exit 1; }
ENTRY="$(printf '%08x' "0x$ENTRY")"
case "$ENTRY" in
  a0*) : ;;  # 正常:内核入口应为 0xa0xxxxxx(DMW0 cached 直映射;stub 只认高字节==0xa0)
  *)  echo "[flash-linux] ★ 入口 0x$ENTRY 高字节不是 a0 — stub 会拒收并死在 mailbox 轮询,拒绝烧录"; exit 1 ;;
esac

# --cmdline: 现场重生成 param_5f.bin(init_5f.txt 同格式,布局对拍
# scripts/linux_bringup/init_5f.txt:两 LE 指针 + "g\0" + cmdline + 0x80 起空 env)
PARAM_TMP=""
if [ -n "$CMDLINE" ]; then
  command -v python3 >/dev/null || { echo "[flash-linux] ★ --cmdline 需要 python3"; exit 1; }
  PARAM_TMP="$(mktemp /tmp/param_5f.XXXXXX.bin)"
  python3 - "$CMDLINE" "$PARAM_TMP" <<'PYEOF'
import struct, sys
cmdline, out = sys.argv[1], sys.argv[2]
# 参数块布局(物理 0x5f00000;stub 已设 a0=2 / a1=0xa5f00000 / a2=0xa5f00080):
#   +0x00 u32LE 0xa5f00010 = argv[0] -> 字符串 "g\0"
#   +0x04 u32LE 0xa5f00012 = argv[1] -> cmdline 字符串(NUL 结尾)
#   +0x80 起   = env 区(a2 指向,全 0 = 空)
# cmdline 必须在 0x80 前结束(含 NUL),否则尾巴会被内核当 env 字符串读。
c = cmdline.encode()
limit = 0x80 - 0x12 - 1
if len(c) > limit:
    sys.exit("cmdline 太长(最多 %d 字节,现 %d): %r" % (limit, len(c), cmdline))
blk = bytearray(0x130)                     # 304 字节,同 scripts/linux_bringup/init_5f.txt
blk[0:4] = struct.pack('<I', 0xa5f00010)
blk[4:8] = struct.pack('<I', 0xa5f00012)
blk[0x10:0x12] = b'g\x00'
blk[0x12:0x12 + len(c)] = c
with open(out, 'wb') as f:
    f.write(bytes(blk))
PYEOF
  PARAM="$PARAM_TMP"
  echo "[flash-linux] 现场生成 param_5f.bin,cmdline: $CMDLINE"
else
  [ -f "$PARAM" ] || { echo "[flash-linux] ★ 缺 $PARAM(或用 --cmdline \"...\" 现场生成)"; exit 1; }
fi

# ---------- 暂存区 + 补零(linux_load.tcl 残段按 board_load.tcl 约定丢弃,这里保证不触发) ----------
mkdir -p "$SCRATCH"
SW="$(wslpath -w "$SCRATCH")"            # /mnt/c/... -> C:\...
cp "$VMLINUX" "$SCRATCH/vmlinux.bin"
cp "$PARAM"   "$SCRATCH/param_5f.bin"
[ "$LOAD_STUB" -eq 1 ] && cp "$STUB" "$SCRATCH/start_board.bin"
cp "$REPO/scripts/board/linux_load.tcl" "$SCRATCH/"
[ -z "$PARAM_TMP" ] || rm -f "$PARAM_TMP"   # 临时 param 已拷进暂存区,用完即删

pad4 () {  # 补零到 4 字节整倍数(JTAG 载入按 32-bit word 走)
  local sz pad
  sz="$(stat -c %s "$1")"
  pad=$(( (4 - sz % 4) % 4 ))
  [ "$pad" -gt 0 ] && head -c "$pad" /dev/zero >> "$1" || true
}
pad4 "$SCRATCH/vmlinux.bin"
pad4 "$SCRATCH/param_5f.bin"
[ "$LOAD_STUB" -eq 1 ] && pad4 "$SCRATCH/start_board.bin"

# 必须从 C: 盘 cwd 启动 cmd.exe(UNC cwd 会「系统找不到指定的路径」)
run () { ( cd "$SCRATCH" && "$CMD" /c "$VIVADO_WIN_BAT -mode batch -source $SW\\$1" ) ; }

TS="$(date +%Y%m%d_%H%M%S)"
PROG_LOG="/tmp/flash_linux_${TS}_prog.log"
LOAD_LOG="/tmp/flash_linux_${TS}_load.log"

# ---------- 1/2 烧 bitstream(可选) ----------
if [ "$NO_BIT" -eq 0 ]; then
  if [ -z "$BIT" ]; then
    # 优先 Linux SoC 工程(board/linux_soc)的综合产物
    BIT="$(find "$REPO/board/linux_soc" -name '*.bit' -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk 'NR==1{sub(/^[^ ]+ /,""); print}')"
    if [ -z "$BIT" ]; then
      BIT="$(ls -t "$REPO"/synth/results/*_soc/soc_top.bit 2>/dev/null | head -1 || true)"
      if [ -n "$BIT" ]; then
        echo "[flash-linux] ⚠ 没找到 board/linux_soc 综合产物,fallback bench SoC bit: $BIT"
        echo "               (bench SoC 无 ns16550 UART 等 Linux 外设,只能验 JTAG 载入链路,Linux 起不来)"
      fi
    fi
  fi
  [ -n "$BIT" ] && [ -f "$BIT" ] || { echo "[flash-linux] ★ 找不到 bitstream(给个参数,或先综合 Linux SoC 工程)"; exit 1; }
  cp "$BIT" "$SCRATCH/soc_top.bit"
  cp "$REPO/scripts/board/program.tcl" "$SCRATCH/"
  echo "[flash-linux] 1/2 烧 bitstream: $BIT"
  run "program.tcl -tclargs $SW\\soc_top.bit" > "$PROG_LOG" 2>&1 || true
  iconv -f GBK -t UTF-8 "$PROG_LOG" 2>/dev/null | grep -aE "PROGRAM_DONE|done_status|ERROR|找不到|startup status" | tail -4 || true
  grep -qa PROGRAM_DONE "$PROG_LOG" || { echo "[flash-linux] ★ 烧录失败(见 $PROG_LOG;查 JTAG 线 / VIVADO_WIN_BAT)"; exit 1; }
else
  echo "[flash-linux] 跳过烧 bit(--no-bit),只载镜像 + 复位重启..."
fi

# ---------- 2/2 载镜像 + 写 mailbox + 放复位(带进度) ----------
# 可选 env LINUX_LOAD_MAX_WORDS:burst 档位覆盖(tclarg 3)。默认 256=板证档位
# (AXI4 INCR / JTAG-AXI PG174 的 256-beat 硬上限);>256 是实验档,板上实测通过
# 前别用 —— 超限失败 linux_load.tcl 会整体报错停机,不做中途降档重发。
# stub 是 tclarg 4,所以 max_words(tclarg 3)必须显式给出(默认板证 256)
MW="${LINUX_LOAD_MAX_WORDS:-256}"
[[ "$MW" =~ ^[0-9]+$ ]] || { echo "[flash-linux] ★ LINUX_LOAD_MAX_WORDS 要整数: $MW"; exit 1; }
[ "$MW" -le 256 ] || echo "[flash-linux] ⚠ LINUX_LOAD_MAX_WORDS=$MW >256(实验档,超 PG174 上限)"
VMSZ="$(du -h "$SCRATCH/vmlinux.bin" | cut -f1)"
STUB_ARG=""
if [ "$LOAD_STUB" -eq 1 ]; then
  STUB_ARG=" $SW\\\\start_board.bin"
  echo "[flash-linux] 2/2 载 stub@0x1c000000(路线C) + vmlinux.bin(${VMSZ})@0x300000 + param@0x5f00000 + entry 0x${ENTRY}->mailbox ..."
else
  echo "[flash-linux] 2/2 载 vmlinux.bin(${VMSZ})@0x300000 + param@0x5f00000 + entry 0x${ENTRY}->mailbox(stub 已在 SPI flash)..."
fi
run "linux_load.tcl -tclargs $SW\\vmlinux.bin $SW\\param_5f.bin $ENTRY $MW${STUB_ARG}" > "$LOAD_LOG" 2>&1 &
LOAD_PID=$!
# 实时吐 LOAD_STAGE / LOAD_PROGRESS / LOAD_CHECK(标记行是纯 ASCII,GBK 日志里 grep -a 直接可用)
tail --pid="$LOAD_PID" -n +1 -f "$LOAD_LOG" 2>/dev/null \
  | grep --line-buffered -aE "LOAD_STAGE|LOAD_PROGRESS|LOAD_NOTE|LOAD_CHECK|SPOT_CHECK" \
  | sed -u 's/\r$//; s/^/[flash-linux]   /' || true
wait "$LOAD_PID" || true

if grep -qa LINUX_LOADED_AND_BOOTING "$LOAD_LOG"; then
  echo "[flash-linux] ✓ 完成 — 复位已释放,板上 Linux 正在启动"
  echo "  打开串口终端看内核日志:板载 USB-串口,115200-8N1"
  echo "    Windows: PuTTY/MobaXterm 选对应 COM 口;WSL: minicom -D /dev/ttySn -b 115200"
  echo "  预期: 'uart work!'(stub)→ 'Linux version 5.14.0-rc2'→ ...→ '#'(busybox shell)"
else
  echo "[flash-linux] ★ 载入失败(完整日志 $LOAD_LOG),错误摘录:"
  iconv -f GBK -t UTF-8 "$LOAD_LOG" 2>/dev/null | grep -aE "ERROR|error|找不到|Failed" | tail -5 || true
  exit 1
fi
