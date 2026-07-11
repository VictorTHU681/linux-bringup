> **本文档是启动路线 A(SPI 烧 stub)的操作指引——当前主路线。**

# 一次性 SPI flash stub 烧写指引(Linux 启动路线 A)

> 目标:把微型复位 stub(`start_board.bin`)烧进 FPGA 板上的 SPI flash 芯片。
> **只需做一次**——之后日常内核迭代全部走 `./scripts/flash-linux.sh`(JTAG 直载),
> 不再碰 flash。

## 为什么要这一步(路线 A 的设计)

- NOP-SoC 地址图里 `0x1c000000`(核复位 PC)= **SPI flash XIP 区**。我们不动地址
  译码(保持 PMON / 官方镜像兼容),所以复位后核执行的第一段代码必须躺在 flash 里。
- stub 由 `scripts/linux_bringup/board/gen-boot-images.sh` 生成(产物
  `.linux_bringup/board_images/start_board.bin`),干四件事:
  1. 初始化 UART `0x1fe001e0`(板上 aclk=33.33MHz,divisor=33333333/(16×115200)=18,
     波特误差 +0.46%),打印 `uart work!`;
  2. 设 DMW0=`0xa0000001` / DMW1=`0x00000001`,开 CRMD.PG;
  3. 设内核约定寄存器 a0=2 / a1=0xa5f00000 / a2=0xa5f00080;
  4. **从 mailbox `0xa5f000a0`(物理 0x05f000a0)`ld.w` 出内核入口地址,`jirl` 跳过去**。
- 入口地址走 mailbox(由 `flash-linux.sh` 每次经 JTAG 写入)→ **内核重编 / 换
  cmdline / 换入口都不用重烧 flash**。只有 stub 自身的协议(mailbox 地址、寄存器
  约定)变了才需要重烧。

## 烧写步骤(官方串口 xmodem 流程)

完整图文见 `chiplab/docs/FPGA_run_linux/flash.md`(含 minicom / ECOM / SecureCRT
截图),这里按我们板子(xc7a200tfbg676-2,WSL + Windows Vivado)提炼:

1. **准备**:flash 芯片插好在 FPGA 开发板上;接 JTAG 下载线 + 串口线;板上电。
2. **下载官方烧写器 bit**(把 flash 烧写逻辑放进 FPGA):
   ```bash
   curl -LO https://gitee.com/chenzes/chiplab-tools/releases/download/chiplab-tools/programmer_by_uart.bit
   ```
   像烧普通 bit 一样烧进去。可直接复用本仓库的 `program.tcl`(只烧 bit,不碰
   JTAG-AXI,烧写器 bit 里没有 hw_axi 也没关系):
   ```bash
   SCRATCH="${VIVADO_WSL_SCRATCH:-/mnt/c/Users/Public/vivado-wsl}"; mkdir -p "$SCRATCH"
   cp programmer_by_uart.bit "$SCRATCH/"; cp scripts/board/program.tcl "$SCRATCH/"
   SW="$(wslpath -w "$SCRATCH")"
   ( cd "$SCRATCH" && /mnt/c/Windows/System32/cmd.exe /c \
       "$VIVADO_WIN_BAT -mode batch -source $SW\\program.tcl -tclargs $SW\\programmer_by_uart.bit" )
   ```
3. **串口连接**:打开串口软件,波特率 **230400**(⚠ 这是烧写器的波特率;之后看内核
   日志才是 115200,别混)。8N1、无流控。
4. 串口有提示后,键盘输入 `x` 表示开始 xmodem 传输。
5. 串口软件用 **xmodem 模式**发送 `.linux_bringup/board_images/start_board.bin`。
   官方口径速率 ~6KB/s —— stub 只有几百字节到几 KB,**数秒即完**。
   (WSL 下推荐 minicom:`Ctrl-A s` → xmodem → 选文件;详见 flash.md。)
6. 传输完成后,**重新烧回 Linux SoC 的 `soc_top.bit`**(直接跑
   `./scripts/flash-linux.sh` 即可,它的 1/2 步就是烧 bit)。

## 验证 stub 在位

- 烧完 stub、还没载内核时,直接放复位(或跑一次 `flash-linux.sh --no-bit` 前先别
  期待内核起来):串口 **115200** 应能看到 stub 打的 `uart work!`。
- 之后 stub 会去读 mailbox —— 若 mailbox 还是上电垃圾值,`jirl` 跳飞是**正常现象**;
  日常流程 `flash-linux.sh` 总是先写好 vmlinux/param/mailbox 再放复位,不存在这个窗口。

## 替代方案 B:PMON(官方 bootloader 路线)

不想用 stub,可以烧官方 PMON,走 tftp / 串口加载内核:

```bash
curl -LO https://gitee.com/chenzes/chiplab-tools/releases/download/pmon/gzrom.bin
```

- 烧写流程与上面完全相同(xmodem 发 `gzrom.bin`;体积大得多,6KB/s 下要几分钟到
  十几分钟,耐心等)。
- NOP-SoC 完整保留 loongson 地址图(UART `0x1fe001e0` / CONFREG `0x1fd0_xxxx` /
  MAC `0x1ff0_xxxx`,SPI XIP `0x1c000000`)→ **PMON 大概率直接可用**;板上 MAC 在,
  PMON 里可 `tftp` 拉内核。
- 代价:每次载内核依赖网络环境 / 串口速率,不如路线 A 的 JTAG 直载
  (~百 KB/s 级)顺手;两条路线共存无冲突——flash 里烧谁,复位后就走谁。

## 备注

- 若 `gen-boot-images.sh` 尚未就绪,`start_board.bin` 可手工汇编:以
  `/home/wangchenjie/y3t2/chiplab-fresh/software/examples/linux/start.S` 为底,
  divisor 1→18(板上 33.33MHz),`li.w $r12, KERNEL_ENTRY_ADDRESS` 一行改成从
  `0xa5f000a0` `ld.w`,工具链用
  `chiplab/toolchains/loongson-gnu-toolchain-8.3-.../bin/loongarch32r-linux-gnusf-*`。
- 烧写器 bit / PMON 均为官方产物,链接失效时去
  `https://gitee.com/chenzes/chiplab-tools/releases` 找同名 release。
