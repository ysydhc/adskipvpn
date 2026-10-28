import { vpnExtension, socket } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { commonEventManager, BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AdDomainRules } from './AdDomainRules';
import { DnsPacketParser, ParsedDnsQuery } from './DnsPacketParser';

const TAG = 'AdSkipVpnEngine';
const DOMAIN = 0x0001;

export const VPN_LOG_EVENT = 'com.example.adskipvpn.EVENT_VPN_LOG';
export const VPN_CMD_EVENT = 'com.example.adskipvpn.EVENT_VPN_CMD';
export const VPN_TRACE_LOG_FILE = '/vpn_dns_trace.log';

interface PendingDnsContext {
  seq: number;
  startTimeMs: number;
  isSuspect: boolean;
  query: ParsedDnsQuery;
}

/**
 * 本地 VPN DNS 广告拦截与全链路诊断核心引擎
 * 采用“虚拟 DNS (10.88.0.1/32) + 腾讯 HTTPDNS 专用 IP 路由接管”架构：
 * 1. 普通音视频/网页 TCP 流量直连物理网卡，零性能损耗
 * 2. 拦截直连 HTTPDNS IP (182.254.116.116 / 182.254.118.118 / 119.29.29.98 / 119.29.29.99) 并回写 TCP RST 迫使回退系统 DNS
 * 3. 对所有系统 DNS 请求记录全链路日志（序号、域名、记录类型、命中规则、上游真实解析 IP 与耗时），持久化至沙箱文件供 UI 跨进程回溯
 */
export class VpnAdBlockEngine {
  private static instance: VpnAdBlockEngine = new VpnAdBlockEngine();
  private vpnConnection: vpnExtension.VpnConnection | null = null;
  private tunFd: number = -1;
  private isRunning: boolean = false;
  private upstreamUdp: socket.UDPSocket | null = null;
  private pendingQueries: Map<number, PendingDnsContext> = new Map<number, PendingDnsContext>();
  private cmdSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private filesDir: string = '';

  // 诊断统计计数器
  private rawPacketSeq: number = 0;
  private dnsQueryCount: number = 0;
  private blockedCount: number = 0;
  private watchCount: number = 0;
  private allowedCount: number = 0;
  private httpDnsBlockedCount: number = 0;

  // 拦截接管的腾讯系 HTTPDNS 专用 Anycast IP
  private static readonly HTTPDNS_IPS: string[] = [
    '182.254.116.116',
    '182.254.118.118',
    '119.29.29.98',
    '119.29.29.99'
  ];

  public static getInstance(): VpnAdBlockEngine {
    return VpnAdBlockEngine.instance;
  }

  /**
   * 启动 VPN 虚拟网卡与 DNS 分流循环
   */
  public async start(context: vpnExtension.VpnExtensionContext): Promise<number> {
    this.filesDir = context.filesDir;
    const syncedCount = AdDomainRules.syncCustomRulesFromDisk(this.filesDir);
    this.subscribeUiCommands();

    if (this.isRunning && this.tunFd > 0) {
      this.publishLog(
        'INFO',
        `VPN 引擎已在运行 (tunFd=${this.tunFd} | 累计包=${this.rawPacketSeq} | 拦截=${this.blockedCount} | 可疑监控=${this.watchCount} | 放行=${this.allowedCount} | 规则数=${AdDomainRules.getAllRules().length})`
      );
      return this.tunFd;
    }

    try {
      this.vpnConnection = vpnExtension.createVpnConnection(context);

      // 构造路由表：10.88.0.1/32 (虚拟DNS) + 腾讯 HTTPDNS 专用 IP/32
      const routes: vpnExtension.RouteInfo[] = [
        {
          interface: 'vpn-tun',
          destination: {
            address: { address: '10.88.0.1', family: 1 },
            prefixLength: 32
          },
          gateway: { address: '10.88.0.1', family: 1 },
          hasGateway: false,
          isDefaultRoute: false
        }
      ];

      for (const httpDnsIp of VpnAdBlockEngine.HTTPDNS_IPS) {
        routes.push({
          interface: 'vpn-tun',
          destination: {
            address: { address: httpDnsIp, family: 1 },
            prefixLength: 32
          },
          gateway: { address: '10.88.0.1', family: 1 },
          hasGateway: false,
          isDefaultRoute: false
        });
      }

      const config: vpnExtension.VpnConfig = {
        addresses: [
          {
            address: { address: '10.88.0.2', family: 1 },
            prefixLength: 24
          }
        ],
        routes: routes,
        dnsAddresses: ['10.88.0.1'],
        mtu: 1400,
        isIPv4Accepted: true,
        isIPv6Accepted: false,
        isInternal: false,
        isBlocking: false
      };

      this.tunFd = await this.vpnConnection.create(config);
      this.isRunning = true;
      this.publishLog(
        'START',
        `TUN 隧道已激活 (tunFd=${this.tunFd}, 虚拟DNS=10.88.0.1, 接管HTTPDNS=[${VpnAdBlockEngine.HTTPDNS_IPS.join(',')}], 规则总数=${AdDomainRules.getAllRules().length}, 磁盘自定义=${syncedCount})`
      );

      // 初始化上游公共 DNS (223.5.5.5:53) 转发 Socket
      await this.initUpstreamSocket();

      // 启动异步 TUN 数据包读取循环
      this.runTunReadLoop();
      return this.tunFd;
    } catch (err) {
      const error = err as BusinessError;
      this.publishLog('ERROR', `创建 VPN 失败: code=${error.code}, msg=${error.message}`);
      throw err as Error;
    }
  }

  /**
   * 监听来自 UI 进程的诊断指令（如插入抓包标记、热加载新规则、清空日志）
   */
  private subscribeUiCommands(): void {
    if (this.cmdSubscriber !== null) {
      return;
    }
    const info: commonEventManager.CommonEventSubscribeInfo = {
      events: [VPN_CMD_EVENT]
    };
    commonEventManager.createSubscriber(info).then((sub: commonEventManager.CommonEventSubscriber) => {
      this.cmdSubscriber = sub;
      commonEventManager.subscribe(sub, (err: BusinessError, data: commonEventManager.CommonEventData) => {
        if (err || !data || !data.data) {
          return;
        }
        const cmd = data.data;
        if (cmd === 'RELOAD_RULES') {
          const added = AdDomainRules.syncCustomRulesFromDisk(this.filesDir);
          this.publishLog('RULE', `VPN 进程已热同步自定义规则 (+${added} 条)，当前生效总规则数: ${AdDomainRules.getAllRules().length}`);
        } else if (cmd.startsWith('MARK:')) {
          const label = cmd.substring(5);
          this.publishLog(
            'MARK',
            `========== ${label} (TUN包=${this.rawPacketSeq} | 拦截=${this.blockedCount} | HTTPDNS阻断=${this.httpDnsBlockedCount} | 可疑=${this.watchCount}) ==========`
          );
        } else if (cmd === 'STATUS') {
          this.publishLog(
            'STATS',
            `状态快照: 运行中=${this.isRunning}, tunFd=${this.tunFd}, 总包=${this.rawPacketSeq}, DNS=${this.dnsQueryCount}, 拦截=${this.blockedCount}, HTTPDNS阻断=${this.httpDnsBlockedCount}, 可疑=${this.watchCount}, 放行=${this.allowedCount}`
          );
        }
      });
    }).catch(() => {});
  }

  /**
   * 停止 VPN 虚拟网卡并释放资源
   */
  public async stop(): Promise<void> {
    this.isRunning = false;
    this.pendingQueries.clear();

    if (this.upstreamUdp !== null) {
      try {
        await this.upstreamUdp.close();
      } catch (_) {
      }
      this.upstreamUdp = null;
    }

    if (this.vpnConnection !== null) {
      try {
        await this.vpnConnection.destroy();
        this.publishLog(
          'STOP',
          `已销毁 VPN 连接 (本次会话共处理包=${this.rawPacketSeq}, 拦截广告DNS=${this.blockedCount}, 阻断HTTPDNS=${this.httpDnsBlockedCount})`
        );
      } catch (err) {
        const error = err as BusinessError;
        this.publishLog('ERROR', `销毁 VPN 异常: ${error.message}`);
      }
      this.vpnConnection = null;
    }
    this.tunFd = -1;
  }

  /**
   * 初始化用于向 223.5.5.5 转发正常域名请求的 UDP Socket
   */
  private async initUpstreamSocket(): Promise<void> {
    const udp = socket.constructUDPSocketInstance();
    await udp.bind({ address: '0.0.0.0', port: 0, family: 1 });

    udp.on('message', (info: socket.SocketMessageInfo) => {
      this.handleUpstreamDnsResponse(new Uint8Array(info.message));
    });

    udp.on('error', (err: BusinessError) => {
      this.publishLog('ERROR', `上游 UDP Socket 异常: code=${err.code}, msg=${err.message}`);
    });

    this.upstreamUdp = udp;
  }

  /**
   * 处理上游 223.5.5.5 返回的正常域名 DNS 响应，提取解析 IP 记录日志并封装回写到 tunFd
   */
  private handleUpstreamDnsResponse(dnsPayload: Uint8Array): void {
    if (dnsPayload.length < 12 || this.tunFd < 0 || !this.isRunning) {
      return;
    }
    const txId = (dnsPayload[0] << 8) | dnsPayload[1];
    const ctx = this.pendingQueries.get(txId);
    if (!ctx) {
      return;
    }
    this.pendingQueries.delete(txId);

    const costMs = Date.now() - ctx.startTimeMs;
    const answerIps = DnsPacketParser.extractAnswerIps(dnsPayload, ctx.query.questionEndOffset);
    const ipSummary = answerIps.length > 0 ? answerIps.join(', ') : (ctx.query.qtype === 28 ? 'IPv6/AAAA响应' : '无A记录');

    // 如果是重点关注的可疑域名（如 QQ 音乐 / 腾讯系 / 广告相关），在收到上游响应时也输出完整解析 IP 日志
    if (ctx.isSuspect) {
      this.publishLog(
        'WATCH',
        `#${ctx.seq} [解析完成] ${ctx.query.domain} (${ctx.query.qtypeName}) -> [${ipSummary}] (耗时=${costMs}ms)`
      );
    }

    const responsePacket = DnsPacketParser.wrapDnsResponseInIpv4Udp(ctx.query, dnsPayload);
    this.writePacketToTun(responsePacket);
  }

  /**
   * 持续从 tunFd 非阻塞轮询读取进入虚拟网卡的所有 IPv4 报文（避免阻塞线程触发鸿蒙后台 AppFreeze 查杀）
   */
  private async runTunReadLoop(): Promise<void> {
    const buffer = new ArrayBuffer(2048);
    while (this.isRunning && this.tunFd > 0) {
      let hasPacket = false;
      try {
        const bytesRead = fileIo.readSync(this.tunFd, buffer);
        if (bytesRead > 0) {
          hasPacket = true;
          const packet = new Uint8Array(buffer, 0, bytesRead);
          await this.processTunPacket(packet, bytesRead);
        }
      } catch (err) {
        if (!this.isRunning) {
          break;
        }
        const error = err as BusinessError;
        // EAGAIN (13900010 / 13900034) 表示当前无数据可读，短暂让出事件循环
        if (error.code === 13900010 || error.code === 13900034) {
          await this.sleep(15);
          continue;
        }
        this.publishLog('ERROR', `TUN 读取异常: code=${error.code}, msg=${error.message}`);
        break;
      }
      if (!hasPacket) {
        await this.sleep(15);
      }
    }
  }

  /**
   * 全链路诊断与分流处理单个 IPv4 包：
   * 1. 检查是否为直连 HTTPDNS IP 的非 DNS 流量 -> 回写 TCP RST / 丢弃并打印 [HTTPDNS] 告警
   * 2. 解析 UDP 53 DNS 查询 -> 命中规则返回 0.0.0.0/NXDOMAIN 并记录命中规则名；未命中则区分 [WATCH] (QQ/腾讯/广告相关) 与 [ALLOW]
   */
  private async processTunPacket(packet: Uint8Array, length: number): Promise<void> {
    this.rawPacketSeq += 1;
    const seq = this.rawPacketSeq;

    // 1. 尝试作为标准 UDP 53 DNS 查询报文解析
    const query = DnsPacketParser.parseIpv4DnsQuery(packet, length);
    if (query === null) {
      // 非 UDP 53 报文：解析 IPv4 五元组，检查是否为 App 试图直连腾讯 HTTPDNS IP 绕过系统 DNS
      const summary = DnsPacketParser.parseIpv4Summary(packet, length);
      if (summary !== null) {
        if (VpnAdBlockEngine.HTTPDNS_IPS.includes(summary.dstIpStr)) {
          this.httpDnsBlockedCount += 1;
          if (summary.protocol === 6) {
            // TCP 直连 HTTPDNS (如 80/443 端口)：立即回写 TCP RST+ACK 使其毫秒级失败并回退系统 DNS
            const rstPkt = DnsPacketParser.buildTcpResetPacket(packet, length);
            if (rstPkt !== null) {
              this.writePacketToTun(rstPkt);
            }
            this.publishLog(
              'BLOCK',
              `#${seq} [阻断HTTPDNS直连] TCP ${summary.srcIpStr}:${summary.srcPort} -> ${summary.dstIpStr}:${summary.dstPort} (已回写TCP-RST迫使App回退系统DNS)`
            );
          } else {
            this.publishLog(
              'BLOCK',
              `#${seq} [阻断HTTPDNS直连] Proto=${summary.protocol} ${summary.srcIpStr}:${summary.srcPort} -> ${summary.dstIpStr}:${summary.dstPort} (len=${length}, 已丢弃)`
            );
          }
        } else if (summary.protocol !== 17) {
          // 诊断记录其他进入 TUN 的非预期协议报文
          hilog.debug(
            DOMAIN,
            TAG,
            '#%{public}d [NON-DNS] proto=%{public}d %{public}s:%{public}d -> %{public}s:%{public}d len=%{public}d',
            seq,
            summary.protocol,
            summary.srcIpStr,
            summary.srcPort,
            summary.dstIpStr,
            summary.dstPort,
            length
          );
        }
      }
      return;
    }

    this.dnsQueryCount += 1;
    const txIdHex = query.transactionId.toString(16).padStart(4, '0');

    // 2. 检查域名是否命中广告拦截黑名单
    const matchedRule = AdDomainRules.matchRule(query.domain);
    if (matchedRule !== null) {
      this.blockedCount += 1;
      const blockedPacket = DnsPacketParser.buildBlockedDnsResponsePacket(query);
      this.writePacketToTun(blockedPacket);
      const sinkholeDesc = query.qtype === 1 ? '0.0.0.0 (Sinkhole)' : 'NXDOMAIN (禁IPv6/HTTPS绕过)';
      this.publishLog(
        'BLOCK',
        `#${seq} 拦截广告DNS: ${query.domain} | 类型=${query.qtypeName} | 命中规则=[${matchedRule}] -> ${sinkholeDesc} (tx=0x${txIdHex})`
      );
      return;
    }

    // 3. 未命中黑名单：检查是否为重点监控的可疑关联域名（如广告/统计/CDN 关联域名）
    const isSuspect = AdDomainRules.isSuspectDomain(query.domain);
    if (isSuspect) {
      this.watchCount += 1;
      this.publishLog(
        'WATCH',
        `#${seq} 发现可疑关联域名: ${query.domain} | 类型=${query.qtypeName} (tx=0x${txIdHex}) -> 正在查询上游`
      );
    } else {
      this.allowedCount += 1;
      this.publishLog(
        'ALLOW',
        `#${seq} 普通放行: ${query.domain} | 类型=${query.qtypeName}`
      );
    }

    // 4. 转发给阿里公共 DNS (223.5.5.5:53)
    this.pendingQueries.set(query.transactionId, {
      seq: seq,
      startTimeMs: Date.now(),
      isSuspect: isSuspect,
      query: query
    });

    if (this.upstreamUdp !== null) {
      try {
        const payloadCopy = query.dnsPayload.buffer.slice(
          query.dnsPayload.byteOffset,
          query.dnsPayload.byteOffset + query.dnsPayload.byteLength
        );
        await this.upstreamUdp.send({
          data: payloadCopy,
          address: { address: '223.5.5.5', port: 53, family: 1 }
        });
      } catch (err) {
        const error = err as BusinessError;
        this.publishLog('ERROR', `#${seq} 转发上游 DNS (${query.domain}) 失败: ${error.message}`);
      }
    }
  }

  /**
   * 将构造好的 IPv4 响应包写回 TUN 虚拟网卡
   */
  private writePacketToTun(packet: Uint8Array): void {
    if (this.tunFd < 0 || !this.isRunning) {
      return;
    }
    try {
      const outBuffer = packet.buffer.slice(packet.byteOffset, packet.byteOffset + packet.byteLength);
      fileIo.writeSync(this.tunFd, outBuffer);
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(DOMAIN, TAG, '写回 TUN 失败: %{public}s', error.message);
    }
  }

  /**
   * 统一输出诊断日志：
   * 1. 打印到系统 hilog (标签 AdSkipVpnEngine)
   * 2. 追加写入应用沙箱共享文件 vpn_dns_trace.log（确保从 QQ 音乐切回本应用时日志完整不丢失）
   * 3. 广播 CommonEvent 供前台 UI 实时刷新
   */
  private publishLog(type: string, message: string): void {
    const now = new Date();
    const timeStr =
      `${now.getHours().toString().padStart(2, '0')}:` +
      `${now.getMinutes().toString().padStart(2, '0')}:` +
      `${now.getSeconds().toString().padStart(2, '0')}.` +
      `${now.getMilliseconds().toString().padStart(3, '0')}`;
    const fullLine = `${timeStr} [${type}] ${message}`;

    hilog.info(DOMAIN, TAG, '%{public}s', fullLine);
    this.appendLogToDisk(fullLine);

    try {
      commonEventManager.publish(
        VPN_LOG_EVENT,
        {
          data: fullLine
        },
        () => {}
      );
    } catch (_) {
    }
  }

  /**
   * 将日志持久化到应用沙箱文件，解决 UI 切后台被挂起或跨进程日志丢失问题
   */
  private appendLogToDisk(line: string): void {
    if (!this.filesDir) {
      return;
    }
    try {
      const path = this.filesDir + VPN_TRACE_LOG_FILE;
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND);
      fileIo.writeSync(file.fd, `${line}\n`);
      fileIo.closeSync(file);
    } catch (_) {
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => resolve(), ms);
    });
  }
}
