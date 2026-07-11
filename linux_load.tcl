# linux_load.tcl — 经 JTAG-AXI(hw_axi_1)载 Linux 内核镜像 + 启动参数块,把内核入口
# 写进 mailbox,然后释放 CPU 复位。由 scripts/flash-linux.sh 调用。
# 软复位约定沿用 board_load.tcl(jtag_axi_wrap 偷听自身 AW:写地址 0x80000000 =
# 压住 core_rst_n、0x40000000 = 释放)。
#
# 前提(启动路线 A):复位 stub 已一次性烧在 SPI flash(0x1c000000 XIP,烧法见
# scripts/board/flash_spi_stub.md)。stub 起跑后从 mailbox 0xa5f000a0(物理
# 0x05f000a0)ld.w 出内核入口再 jirl —— 所以内核重编只需重跑本脚本,不用重烧 flash。
#
# tclargs:
#   0: vmlinux.bin  (Windows 路径)          -> 0x00300000  内核 raw 镜像
#                                              (链接 0xa0300000,经 DMW0 映射)
#   1: param_5f.bin (Windows 路径)          -> 0x05f00000  cmdline 参数块
#                                              (init_5f.txt 同格式)
#   2: entry_hex    (32-bit hex,如 a02c1000) -> mailbox 0x05f000a0
#   3: max_words    (可选,1~1024 整数)        单 burst word 数,默认 256 = 板证
#                                              档位;>256 超 PG174 上限,实验档,
#                                              板上实测通过前别用(见下)
#
# ⚠ 顺序敏感:mailbox 0x05f000a0 落在 param 块地址范围内(param_5f.bin 通常
#   0x130 字节 > 0xa0),必须【先写 param、再写 mailbox】,否则入口会被 param 的
#   填充 0 盖掉。本文件已按此顺序写死,改动时别调换。
#
# 字节序/残段逻辑与 board_load.tcl 原版逐位等价:
#   - word 内字节反序(小端:文件字节 b0 b1 b2 b3 -> 数据串 "B3B2B1B0",大写 hex);
#   - burst 数据串内 word lreverse(高地址 word 在前);
#   - 残段(文件尾不足 4 字节)丢弃 —— 与原版 `if {$i+3 >= $data_len} break` 同行为。
#     flash-linux.sh 已把镜像补零到 4 字节整倍数,正常流程不会真丢字节;万一触发
#     会打 LOAD_NOTE 告警。
# 相比 board_load.tcl 的改动(不改字节序,vmlinux 4-12MB 逐位拼太慢):
#   1) 每 chunk 一次 `binary scan H*` 转整块 hex 再切 word,不再逐字节逐位转换
#      (提速大头在这;JTAG 吞吐瓶颈是位速率,不是 Tcl 事务开销,加大 burst 收益甚微);
#   2) burst 档位默认 256 beat/1KB = board_load.tcl 板证档位,同时也是 AXI4 INCR
#      与 JTAG-to-AXI master(PG174)的 256-beat 硬上限。>256(如 1024)只能经
#      tclarg 3 opt-in(flash-linux.sh: LINUX_LOAD_MAX_WORDS),且失败即整体报错
#      停机 —— 【不做】中途降档重发:超限 burst 的失败模式可能是驱动静默截断
#      (写坏且无任何报错,catch 根本抓不到)或 jtag_axi FSM 被卡死(此后重发
#      不幂等),见 issue_words;
#   3) 每段镜像写完做 4 探针读回 spot-check(首 / 首 burst 尾 / 中点 / 尾 word,
#      read txn 与文件比对;「首 burst 尾」专抓 2) 里的驱动静默截断 —— 该模式下
#      首尾 word 都完好只烂中间),mailbox 写完也读回比对;把「JTAG 写坏」从
#      不可检测变成即时报错,任一检查失败立即中止,不释放 CPU 复位。
# ⚠ 本机(WSL)无 Windows Vivado,hw_axi 流程未上板验证;chunk_to_words 的字节序
#   已用本地 tclsh 对拍 board_load.tcl 原算法逐位一致(见提交说明)。

open_hw_manager
connect_hw_server
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
refresh_hw_device -update_hw_probes false [current_hw_device]

proc WriteReg { address data } {
    create_hw_axi_txn w [get_hw_axis hw_axi_1] -address $address -data $data -type write
    # 复位偷听地址 0x8000_0000/0x4000_0000 不在新 SoC main_xbar 地址表内(nscscc-team
    # 上是真 RAM),crossbar 会回 DECERR —— 偷听在 jtag_axi_wrap 里已生效,响应码无关
    # 紧要;catch 防 run_hw_axi 对 DECERR 抛 Tcl error。mailbox 写也走本函数,其正确性
    # 由后面的读回比对兜底。
    catch { run_hw_axi w }
    delete_hw_axi_txn w
}

set chunk_size    4096       ;# 每次从文件读 4KB(文件读粒度,与 burst 档位解耦)
set max_words     256        ;# 单 burst word 数,默认 256(1KB)= board_load.tcl 板证
                             ;#  档位 = AXI4 INCR / PG174 256-beat 硬上限;
                             ;#  可被 tclarg 3 覆盖(>256 实验档,见文件头)
set progress_step 262144     ;# 每 256KB 打一行 LOAD_PROGRESS
set total_written 0
set next_progress $progress_step

# 把一个 chunk(字节数须为 4 的倍数)转成 word 列表:每项 8 个大写 hex 字符,
# word 内字节已按小端反序(文件 b0 b1 b2 b3 -> "B3B2B1B0"),word 顺序 = 地址
# 递增顺序(此处不逆序,burst 内 lreverse 由 issue_words 做)。
# 与 board_load.tcl 内层 `format %02X%02X%02X%02X [3][2][1][0]` 输出逐字符相同。
proc chunk_to_words { data } {
    binary scan $data H* hex
    set hex [string toupper $hex]
    set nwords [expr {[string length $data] / 4}]
    set words [list]
    for {set w 0} {$w < $nwords} {incr w} {
        set o [expr {$w * 8}]
        lappend words "[string range $hex [expr {$o + 6}] [expr {$o + 7}]][string range $hex [expr {$o + 4}] [expr {$o + 5}]][string range $hex [expr {$o + 2}] [expr {$o + 3}]][string range $hex [expr {$o + 0}] [expr {$o + 1}]]"
    }
    return $words
}

# 把地址递增顺序的 word 列表按 max_words 切 burst 发出去;发出前对每个 burst 内
# 的 word 做 lreverse(与 board_load.tcl 的 `set temp_data [lreverse $temp_data]`
# 一致:数据串内高地址 word 在前)。
# 默认 max_words=256 = AXI4 INCR / PG174 硬上限,任何失败都直接 error(不重发)。
# opt-in >256 档失败也直接 error —— 不做「降档从失败处重发」:超限 burst 若把
# jtag_axi FSM 卡死,后续事务不可信,重发不幂等;只能整轮重跑(必要时重插
# JTAG / 重烧 bit)。若驱动是静默截断(无报错),靠写完后的 spot_check 兜底。
proc issue_words { addr_d words } {
    global max_words
    set n [llength $words]
    for {set i 0} {$i < $n} {incr i $max_words} {
        set sub  [lrange $words $i [expr {$i + $max_words - 1}]]
        set data [join [lreverse $sub] "_"]
        set addr [format "%08x" [expr {$addr_d + $i * 4}]]
        if {[catch {
            create_hw_axi_txn bw [get_hw_axis hw_axi_1] -address $addr -len [llength $sub] -type write -data $data
            run_hw_axi bw
            delete_hw_axi_txn bw
        } err]} {
            catch {delete_hw_axi_txn bw}
            if {$max_words > 256} {
                error "超限 burst(len=[llength $sub] > 256)失败 @0x$addr —— jtag_axi 可能已被卡死,不做降档重发。去掉 LINUX_LOAD_MAX_WORDS(回默认 256 档)整轮重跑;若仍失败,重插 JTAG / 重烧 bit 再试。原始错误: $err"
            }
            error "burst 写失败 @0x$addr (len=[llength $sub]): $err"
        }
    }
}

# spot-check:读回 addr_d 处 1 个 word,与期望值(8 个 hex 字符,word 内字节序
# 同写入约定)比对。失配 = JTAG 写入损坏(含「驱动静默截断」这类无报错的写坏)
# → 立即 error,调用方脚本随之中止,CPU 复位不会被释放。
proc spot_check { addr_d expect label } {
    set addr [format "%08x" $addr_d]
    set expect [string toupper $expect]
    if {[catch {
        create_hw_axi_txn rck [get_hw_axis hw_axi_1] -address $addr -len 1 -type read
        run_hw_axi rck
        set got [get_property DATA [get_hw_axi_txns rck]]
        delete_hw_axi_txn rck
    } err]} {
        catch {delete_hw_axi_txn rck}
        error "SPOT_CHECK 读回事务失败($label @0x$addr),镜像完整性未验证,中止: $err"
    }
    # len-1 读回应为 8 个 hex 字符;剥掉可能的 0x 前缀 / 分隔符后取末 8 位归一化
    set got [string toupper [string map {0x "" 0X "" _ ""} $got]]
    set got [string range $got end-7 end]
    if {$got ne $expect} {
        error "SPOT_CHECK 失配($label @0x$addr): 期望 $expect,读回 $got —— JTAG 写入损坏,镜像不可信,不释放 CPU 复位"
    }
    puts "LOAD_CHECK $label @0x$addr OK ($expect)"
    flush stdout
}

proc write_image { path addr_d label } {
    global chunk_size progress_step total_written next_progress max_words
    set base_addr $addr_d
    set nwords [expr {[file size $path] / 4}]
    if {$nwords == 0} {
        error "write_image: $label 不足一个 word,什么都没写: $path"
    }
    # spot-check 探针(按 word 下标):首 / 首 burst 尾(专抓「>256 burst 被驱动
    # 静默截断」—— 该模式下首尾 word 都完好,只烂中间)/ 中点 / 尾。流式写入时
    # 路过就把期望值记下来(O(1) 内存),写完统一读回比对。
    set probe_idx [list 0 [expr {$nwords - 1}]]
    if {$nwords > $max_words} { lappend probe_idx [expr {$max_words - 1}] }
    if {$nwords > 2}          { lappend probe_idx [expr {$nwords / 2}] }
    set probe_idx [lsort -integer -unique $probe_idx]
    set probes [list]    ;# {addr expect_word} 对
    set widx 0           ;# 已流过的 word 数
    set f [open $path "rb"]
    fconfigure $f -translation binary
    while {![eof $f]} {
        set data [read $f $chunk_size]
        set len [string length $data]
        if {$len == 0} break
        # 残段处理与 board_load.tcl 原版等价:不足 4 字节的尾巴【丢弃】(只可能出现
        # 在文件最后一个 chunk)。flash-linux.sh 已提前把镜像补零到 4 字节整倍数,
        # 此分支正常永不触发,触发即告警提醒查镜像。
        set rem [expr {$len % 4}]
        if {$rem != 0} {
            puts "LOAD_NOTE 文件尾 $rem 字节不足一个 word,按 board_load.tcl 约定丢弃(镜像应为 4 字节整倍数): $path"
            flush stdout
            set len [expr {$len - $rem}]
            if {$len == 0} break
            set data [string range $data 0 [expr {$len - 1}]]
        }
        set words [chunk_to_words $data]
        set wcnt [llength $words]
        foreach p $probe_idx {
            if {$p >= $widx && $p < $widx + $wcnt} {
                lappend probes [list [expr {$base_addr + $p * 4}] [lindex $words [expr {$p - $widx}]]]
            }
        }
        incr widx $wcnt
        issue_words $addr_d $words
        incr addr_d $len
        incr total_written $len
        if {$total_written >= $next_progress} {
            puts "LOAD_PROGRESS $total_written"
            flush stdout
            set next_progress [expr {($total_written / $progress_step + 1) * $progress_step}]
        }
    }
    close $f
    # 读回校验(任一失配即 error 中止,不放复位)——「JTAG 写坏」不再静默
    if {[llength $probes] != [llength $probe_idx]} {
        error "write_image: $label 探针只采到 [llength $probes]/[llength $probe_idx] 个(文件在写入中被改动?),中止"
    }
    foreach pr $probes {
        lassign $pr pa pw
        spot_check $pa $pw $label
    }
}

set vmlinux_bin [lindex $argv 0]
set param_bin   [lindex $argv 1]
set entry_raw   [lindex $argv 2]
# tclarg 4(可选):boot-stub bin 路径(路线C fallback)。给了就 JTAG 写到 0x1c000000
# (需 SoC 把 0x1c0 路由到 DDR 折叠区)。不给(路线A 默认,stub 已烧在 SPI flash)则跳过。
set stub_bin ""
if {[llength $argv] >= 5} { set stub_bin [lindex $argv 4] }

# tclarg 3(可选):burst 档位覆盖。默认 256 = 板证档位;>256 为实验档
# (超 AXI4 INCR / PG174 256-beat 上限),板上实测通过前别用于正式载入。
if {[llength $argv] >= 4} {
    set mw [lindex $argv 3]
    if {![string is integer -strict $mw] || $mw < 1 || $mw > 1024} {
        error "max_words 非法(要 1~1024 整数,默认 256=板证档位): $mw"
    }
    set max_words $mw
    if {$max_words > 256} {
        puts "LOAD_NOTE max_words=$max_words 超 AXI4 INCR/PG174 256-beat 上限(实验档);失败不降档重发,只能整轮重跑"
        flush stdout
    }
}

# 入口地址规整成 8 个大写 hex(容忍带/不带 0x 前缀);非法就趁早报错,
# 别把垃圾写进 mailbox 让 stub 跑飞。
set entry_hex [string map {0x "" 0X ""} $entry_raw]
if {![regexp {^[0-9a-fA-F]{1,8}$} $entry_hex]} {
    error "entry_hex 非法(应为 32-bit hex,如 a02c1000): $entry_raw"
}
set entry_hex [string toupper [format "%08x" [expr {"0x$entry_hex"}]]]

# 载入期间按住 CPU 复位(MIG/DDR/JTAG-AXI 不受影响,直写内存)
WriteReg 80000000 00000000

if {$stub_bin ne ""} {
    puts "LOAD_STAGE start_board.bin -> 0x1c000000 (路线C: DDR 折叠区 boot-stub)"
    flush stdout
    write_image $stub_bin [expr {0x1c000000}] "start_board.bin"
}

puts "LOAD_STAGE vmlinux.bin -> 0x00300000"
flush stdout
write_image $vmlinux_bin [expr {0x00300000}] "vmlinux.bin"

puts "LOAD_STAGE param_5f.bin -> 0x05f00000"
flush stdout
write_image $param_bin [expr {0x05f00000}] "param_5f.bin"

# mailbox 必须最后写(param 块会盖到 0xa0 偏移,见文件头「顺序敏感」)。
# 单 word 写:数据串 = 32-bit 值的 hex(MSB 在前),落内存即小端字节序,
# stub 的 ld.w 读回原值 —— 与 burst word 的字节序约定同一套。
puts "LOAD_STAGE entry 0x$entry_hex -> mailbox 0x05f000a0"
flush stdout
WriteReg 05f000a0 $entry_hex
spot_check [expr {0x05f000a0}] $entry_hex "mailbox入口"

# 释放复位 -> CPU 从 0x1c000000 起跑(路线A=SPI XIP flash stub;路线C=JTAG 写的 DDR stub),
# stub 读 mailbox 跳内核
puts "LINUX_LOADED_AND_BOOTING entry=0x$entry_hex total_bytes=$total_written"
flush stdout
close_hw_target
close_hw_manager
