#!/usr/bin/env bash
# flash-spi-stub.sh — 一次性全自动把复位 stub 烧进 SPI flash(启动路线 A)。
# 全自动:烧 programmer bit → PowerShell XMODEM 自动传输 start_board.bin → 完成。
# 人只需要接好 JTAG+串口线、给板子上电,然后看输出。
#
# 用法:
#   ./scripts/flash-spi-stub.sh                    # 自动探测 COM 口
#   ./scripts/flash-spi-stub.sh --com COM3         # 指定 COM 口
#   ./scripts/flash-spi-stub.sh --stub PATH        # 自定义 stub bin
#
# 可选 env:
#   VIVADO_WIN_BAT   Windows Vivado 路径(同 flash-board.sh)
#   VIVADO_WSL_SCRATCH  Windows 暂存区(默认 /mnt/c/Users/Public/vivado-wsl)
#
# 前置:
#   - 已跑 gen-boot-images.sh 生成 start_board.bin
#   - 板子 JTAG + 串口线接好,上电
#
# 详细原理见 scripts/board/flash_spi_stub.md
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${VIVADO_WIN_BAT:?未设置 VIVADO_WIN_BAT(你的 Windows vivado.bat 路径)— 见 README 上板烧录}"
SCRATCH="${VIVADO_WSL_SCRATCH:-/mnt/c/Users/Public/vivado-wsl}"
CMD="${WIN_CMD:-/mnt/c/Windows/System32/cmd.exe}"

STUB="${STUB_BIN:-$REPO/.linux_bringup/board_images/start_board.bin}"
COM_PORT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --com)  COM_PORT="${2:?--com 需要 COM 口号(如 COM3)}"; shift 2 ;;
    --stub) STUB="${2:?--stub 需要 stub bin 路径}"; shift 2 ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数: $1(-h 看用法)"; exit 1 ;;
  esac
done

[ -f "$STUB" ] || { echo "[flash-spi-stub] ★ 缺 $STUB — 先跑 ./scripts/linux_bringup/board/gen-boot-images.sh"; exit 1; }

# ── 1. 下载 programmer_by_uart.bit(如缺) ──
PROG_BIT="$REPO/.linux_bringup/programmer_by_uart.bit"
if [ ! -f "$PROG_BIT" ]; then
  echo "[flash-spi-stub] 下载官方 SPI flash 烧写器 bit..."
  curl -L -o "$PROG_BIT" \
    "https://gitee.com/chenzes/chiplab-tools/releases/download/chiplab-tools/programmer_by_uart.bit" \
    || { echo "[flash-spi-stub] ★ 下载失败 — 手动从 https://gitee.com/chenzes/chiplab-tools/releases 下载"; exit 1; }
fi

# ── 2. 准备 Windows 暂存区 ──
mkdir -p "$SCRATCH"
SW="$(wslpath -w "$SCRATCH")"
cp "$PROG_BIT" "$SCRATCH/programmer_by_uart.bit"
cp "$STUB"     "$SCRATCH/start_board.bin"
cp "$REPO/scripts/board/program.tcl"     "$SCRATCH/"
cp "$REPO/scripts/board/xmodem_send.ps1" "$SCRATCH/"

run () { ( cd "$SCRATCH" && "$CMD" /c "$VIVADO_WIN_BAT -mode batch -source $SW\\$1" ) ; }

# ── 3. 烧 programmer_by_uart.bit 到 FPGA ──
echo "[flash-spi-stub] 1/3 烧 programmer_by_uart.bit(SPI flash 烧写器)..."
run "program.tcl -tclargs $SW\\programmer_by_uart.bit" > /tmp/flash_spi_prog.log 2>&1 || true
if ! grep -qa PROGRAM_DONE /tmp/flash_spi_prog.log; then
  echo "[flash-spi-stub] ★ 烧写器 bit 烧录失败(见 /tmp/flash_spi_prog.log)"
  tail -5 /tmp/flash_spi_prog.log
  exit 1
fi
echo "[flash-spi-stub]   ✓ programmer bit 已烧入"

# ── 4. 探测 COM 口(如未指定) ──
if [ -z "$COM_PORT" ]; then
  echo "[flash-spi-stub] 2/3 探测 COM 口..."
  COM_PORTS="$("$CMD" /c "powershell -Command [System.IO.Ports.SerialPort]::GetPortNames()" 2>/dev/null | tr -d '\r' | grep -i '^COM' || true)"
  if [ -z "$COM_PORTS" ]; then
    echo "[flash-spi-stub] ★ 未检测到 COM 口。请用 --com 指定(如 --com COM3),或检查串口线/驱动。"
    exit 1
  fi
  COM_COUNT=$(echo "$COM_PORTS" | wc -l)
  if [ "$COM_COUNT" -eq 1 ]; then
    COM_PORT="$(echo "$COM_PORTS" | head -1)"
    echo "[flash-spi-stub]   自动选中: $COM_PORT"
  else
    echo "[flash-spi-stub]   检测到多个 COM 口:"
    echo "$COM_PORTS" | sed 's/^/    /'
    echo "[flash-spi-stub]   请用 --com 指定其中一个。"
    exit 1
  fi
fi

# ── 5. 确保 Windows Python + pyserial 就绪(首次自动下载 embeddable Python) ──
PY_DIR="$SCRATCH/python312"
if [ ! -f "$PY_DIR/python.exe" ]; then
  echo "[flash-spi-stub] 下载 Windows Python embeddable(首次)..."
  curl -sL -o "$SCRATCH/python-embed.zip" \
    "https://www.python.org/ftp/python/3.12.3/python-3.12.3-embed-amd64.zip"
  unzip -o -q "$SCRATCH/python-embed.zip" -d "$PY_DIR" 2>/dev/null
  sed -i 's/#import site/import site/' "$PY_DIR/python312._pth"
  curl -sL https://bootstrap.pypa.io/get-pip.py -o "$SCRATCH/get-pip.py"
  ( cd "$SCRATCH" && "$PY_DIR/python.exe" get-pip.py --quiet ) 2>&1 | tail -1
  "$PY_DIR/python.exe" -m pip install pyserial --quiet 2>&1 | tail -1
fi
"$PY_DIR/python.exe" -c "import serial" 2>/dev/null || { echo "[flash-spi-stub] ★ pyserial 安装失败"; exit 1; }
cp "$REPO/scripts/board/xmodem_send.py" "$SCRATCH/"

# ── 6. Python(pyserial)XMODEM-CRC 传输(可靠高速串口 I/O) ──
echo "[flash-spi-stub] 3/3 XMODEM 传输 start_board.bin via $COM_PORT @230400 ..."
echo "  (请确保没有其他串口软件占用 $COM_PORT)"
PY_WIN="$(wslpath -w "$PY_DIR")"
( cd "$SCRATCH" && "$CMD" /c "$PY_WIN\\python.exe $SW\\xmodem_send.py $COM_PORT $SW\\start_board.bin" ) 2>&1 \
  | tee /tmp/flash_spi_xmodem.log

# ── 6. 结果判定 ──
if grep -qa "XMODEM_OK" /tmp/flash_spi_xmodem.log; then
  echo ""
  echo "[flash-spi-stub] ✓ SPI flash stub 烧写完成!"
  echo "  下一步: ./scripts/flash-linux.sh   # 烧回 Linux SoC bit + JTAG 载内核"
else
  echo ""
  echo "[flash-spi-stub] ★ XMODEM 传输可能失败(见上方日志)"
  echo "  排查: ① 串口线是否接对 ② 板子是否已上电 ③ COM 口号是否正确"
  echo "  重试: ./scripts/flash-spi-stub.sh --com $COM_PORT"
  exit 1
fi
