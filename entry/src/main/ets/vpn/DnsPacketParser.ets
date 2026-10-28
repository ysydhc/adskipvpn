/**
 * 解析后的 IPv4 通用报文五元组摘要（用于诊断非 DNS 流量，如 HTTPDNS 直连 IP）
 */
export interface Ipv4PacketSummary {
  version: number;
  ihl: number;
  protocol: number; // 6=TCP, 17=UDP, 1=ICMP
  srcIpStr: string;
  dstIpStr: string;
  srcIp: Uint8Array;
  dstIp: Uint8Array;
  srcPort: number;
  dstPort: number;
  tcpFlags: number;
  totalLength: number;
}

/**
 * 解析后的 IPv4 + UDP + DNS 查询报文信息
 */
export interface ParsedDnsQuery {
  ihl: number;
  srcIp: Uint8Array;
  dstIp: Uint8Array;
  srcIpStr: string;
  dstIpStr: string;
  srcPort: number;
  dstPort: number;
  transactionId: number;
  domain: string;
  qtype: number;
  qtypeName: string;
  qclass: number;
  questionEndOffset: number;
  dnsPayload: Uint8Array;
}

/**
 * 纯 ArkTS 实现的 IPv4 + UDP/TCP + DNS 报文解析、诊断与伪造响应构造器
 */
export class DnsPacketParser {
  public static formatIp(ip: Uint8Array): string {
    if (ip.length < 4) {
      return '0.0.0.0';
    }
    return `${ip[0]}.${ip[1]}.${ip[2]}.${ip[3]}`;
  }

  public static getQtypeName(qtype: number): string {
    switch (qtype) {
      case 1:
        return 'A(IPv4)';
      case 28:
        return 'AAAA(IPv6)';
      case 5:
        return 'CNAME';
      case 16:
        return 'TXT';
      case 65:
        return 'HTTPS(SVCB)';
      default:
        return `TYPE_${qtype}`;
    }
  }

  /**
   * 解析任意进入 TUN 网卡的 IPv4 报文五元组摘要
   */
  public static parseIpv4Summary(packet: Uint8Array, length: number): Ipv4PacketSummary | null {
    if (length < 20) {
      return null;
    }
    const version = (packet[0] >> 4) & 0x0f;
    if (version !== 4) {
      return null;
    }
    const ihl = (packet[0] & 0x0f) * 4;
    if (ihl < 20 || length < ihl) {
      return null;
    }
    const protocol = packet[9];
    const srcIp = packet.slice(12, 16);
    const dstIp = packet.slice(16, 20);
    let srcPort = 0;
    let dstPort = 0;
    let tcpFlags = 0;
    if ((protocol === 6 || protocol === 17) && length >= ihl + 4) {
      srcPort = (packet[ihl] << 8) | packet[ihl + 1];
      dstPort = (packet[ihl + 2] << 8) | packet[ihl + 3];
      if (protocol === 6 && length >= ihl + 14) {
        tcpFlags = packet[ihl + 13];
      }
    }
    return {
      version: version,
      ihl: ihl,
      protocol: protocol,
      srcIpStr: DnsPacketParser.formatIp(srcIp),
      dstIpStr: DnsPacketParser.formatIp(dstIp),
      srcIp: srcIp,
      dstIp: dstIp,
      srcPort: srcPort,
      dstPort: dstPort,
      tcpFlags: tcpFlags,
      totalLength: length
    };
  }

  /**
   * 针对直连 HTTPDNS IP 的 TCP SYN 请求构造 TCP RST+ACK 响应，使其毫秒级快速失败并回退系统 DNS
   */
  public static buildTcpResetPacket(rawPacket: Uint8Array, length: number): Uint8Array | null {
    const summary = DnsPacketParser.parseIpv4Summary(rawPacket, length);
    if (summary === null || summary.protocol !== 6 || length < summary.ihl + 20) {
      return null;
    }
    const ihl = summary.ihl;
    const seqNum = (
      ((rawPacket[ihl + 4] << 24) >>> 0) +
      ((rawPacket[ihl + 5] << 16) >>> 0) +
      ((rawPacket[ihl + 6] << 8) >>> 0) +
      (rawPacket[ihl + 7] >>> 0)
    ) >>> 0;
    const ackNum = (seqNum + 1) >>> 0;

    const ipHeaderLen = 20;
    const tcpHeaderLen = 20;
    const totalLen = ipHeaderLen + tcpHeaderLen;
    const rst = new Uint8Array(totalLen);

    // 1. IPv4 Header
    rst[0] = 0x45;
    rst[2] = (totalLen >> 8) & 0xff;
    rst[3] = totalLen & 0xff;
    rst[6] = 0x40;
    rst[8] = 64;
    rst[9] = 6; // TCP
    rst.set(summary.dstIp, 12);
    rst.set(summary.srcIp, 16);
    const ipChecksum = DnsPacketParser.computeIpv4Checksum(rst, ipHeaderLen);
    rst[10] = (ipChecksum >> 8) & 0xff;
    rst[11] = ipChecksum & 0xff;

    // 2. TCP Header (20 bytes)
    rst[20] = (summary.dstPort >> 8) & 0xff;
    rst[21] = summary.dstPort & 0xff;
    rst[22] = (summary.srcPort >> 8) & 0xff;
    rst[23] = summary.srcPort & 0xff;
    // Seq = 0
    rst[24] = 0;
    rst[25] = 0;
    rst[26] = 0;
    rst[27] = 0;
    // Ack = seq + 1
    rst[28] = (ackNum >>> 24) & 0xff;
    rst[29] = (ackNum >>> 16) & 0xff;
    rst[30] = (ackNum >>> 8) & 0xff;
    rst[31] = ackNum & 0xff;
    // Data offset = 5 (20 bytes), Flags = RST (0x04) | ACK (0x10) = 0x14
    rst[32] = 0x50;
    rst[33] = 0x14;
    rst[34] = 0x00;
    rst[35] = 0x00;

    // 计算 TCP 伪首部 + TCP 首部校验和
    const tcpChecksum = DnsPacketParser.computeTcpChecksum(summary.dstIp, summary.srcIp, rst.slice(20, 40));
    rst[36] = (tcpChecksum >> 8) & 0xff;
    rst[37] = tcpChecksum & 0xff;

    return rst;
  }

  /**
   * 从 TUN 网卡读取到的原始 IP 包中解析 UDP 53 端口的 DNS 查询
   */
  public static parseIpv4DnsQuery(packet: Uint8Array, length: number): ParsedDnsQuery | null {
    if (length < 28) {
      return null;
    }

    // 1. 校验 IPv4 (Version = 4)
    const version = (packet[0] >> 4) & 0x0f;
    if (version !== 4) {
      return null;
    }

    const ihl = (packet[0] & 0x0f) * 4;
    if (ihl < 20 || length < ihl + 8) {
      return null;
    }

    // 2. 校验协议类型是否为 UDP (Protocol = 17)
    const protocol = packet[9];
    if (protocol !== 17) {
      return null;
    }

    const srcIp = packet.slice(12, 16);
    const dstIp = packet.slice(16, 20);

    // 3. 解析 UDP 头部
    const srcPort = (packet[ihl] << 8) | packet[ihl + 1];
    const dstPort = (packet[ihl + 2] << 8) | packet[ihl + 3];
    const udpLength = (packet[ihl + 4] << 8) | packet[ihl + 5];

    // 仅处理发往 53 端口的 DNS 请求
    if (dstPort !== 53 || udpLength < 20) {
      return null;
    }

    const dnsOffset = ihl + 8;
    const dnsLength = Math.min(length - dnsOffset, udpLength - 8);
    if (dnsLength < 12) {
      return null;
    }

    const dnsPayload = packet.slice(dnsOffset, dnsOffset + dnsLength);

    // 4. 解析 DNS 头部 (QR 必须为 0，即 Query)
    const transactionId = (dnsPayload[0] << 8) | dnsPayload[1];
    const flags = (dnsPayload[2] << 8) | dnsPayload[3];
    const isResponse = (flags & 0x8000) !== 0;
    const qdCount = (dnsPayload[4] << 8) | dnsPayload[5];
    if (isResponse || qdCount < 1) {
      return null;
    }

    // 5. 解析 Question 区中的域名 (QNAME)
    let pos = 12;
    const labels: string[] = [];
    while (pos < dnsPayload.length) {
      const labelLen = dnsPayload[pos];
      if (labelLen === 0) {
        pos += 1;
        break;
      }
      // 防御压缩指针或非法长度
      if ((labelLen & 0xc0) !== 0 || pos + 1 + labelLen > dnsPayload.length) {
        return null;
      }
      let label = '';
      for (let i = 0; i < labelLen; i++) {
        label += String.fromCharCode(dnsPayload[pos + 1 + i]);
      }
      labels.push(label);
      pos += 1 + labelLen;
    }

    if (pos + 4 > dnsPayload.length || labels.length === 0) {
      return null;
    }

    const qtype = (dnsPayload[pos] << 8) | dnsPayload[pos + 1];
    const qclass = (dnsPayload[pos + 2] << 8) | dnsPayload[pos + 3];
    const questionEndOffset = pos + 4;

    return {
      ihl: ihl,
      srcIp: srcIp,
      dstIp: dstIp,
      srcIpStr: DnsPacketParser.formatIp(srcIp),
      dstIpStr: DnsPacketParser.formatIp(dstIp),
      srcPort: srcPort,
      dstPort: dstPort,
      transactionId: transactionId,
      domain: labels.join('.'),
      qtype: qtype,
      qtypeName: DnsPacketParser.getQtypeName(qtype),
      qclass: qclass,
      questionEndOffset: questionEndOffset,
      dnsPayload: dnsPayload
    };
  }

  /**
   * 从上游返回的 DNS 响应负载中提取解析出的 IPv4 地址列表，并将 TTL 限制为 3 秒（防止系统长时间缓存导致后续打开 App 抓不到 DNS 请求）
   */
  public static extractAnswerIps(dnsPayload: Uint8Array, questionEndOffset: number): string[] {
    const ips: string[] = [];
    if (dnsPayload.length <= questionEndOffset) {
      return ips;
    }
    const anCount = (dnsPayload[6] << 8) | dnsPayload[7];
    let pos = questionEndOffset;
    for (let i = 0; i < anCount && pos < dnsPayload.length; i++) {
      // 跳过 Name 字段（可能是 0xc0 压缩指针或普通 label 序列）
      while (pos < dnsPayload.length) {
        const b = dnsPayload[pos];
        if (b === 0) {
          pos += 1;
          break;
        }
        if ((b & 0xc0) === 0xc0) {
          pos += 2;
          break;
        }
        pos += 1 + b;
      }
      if (pos + 10 > dnsPayload.length) {
        break;
      }
      const rtype = (dnsPayload[pos] << 8) | dnsPayload[pos + 1];
      // 将 Answer 记录的 TTL (pos+4..pos+7) 缩短为 3 秒，确保每次切去打开 QQ 音乐都能重新触发系统 DNS 查询
      dnsPayload[pos + 4] = 0x00;
      dnsPayload[pos + 5] = 0x00;
      dnsPayload[pos + 6] = 0x00;
      dnsPayload[pos + 7] = 0x03;

      const rdlen = (dnsPayload[pos + 8] << 8) | dnsPayload[pos + 9];
      pos += 10;
      if (pos + rdlen > dnsPayload.length) {
        break;
      }
      if (rtype === 1 && rdlen === 4) {
        ips.push(`${dnsPayload[pos]}.${dnsPayload[pos + 1]}.${dnsPayload[pos + 2]}.${dnsPayload[pos + 3]}`);
      }
      pos += rdlen;
    }
    return ips;
  }

  /**
   * 为命中的广告域名构造伪造的 DNS 拦截响应 (Sinkhole -> 0.0.0.0 / NXDOMAIN)
   */
  public static buildBlockedDnsResponsePacket(query: ParsedDnsQuery): Uint8Array {
    const questionSection = query.dnsPayload.slice(12, query.questionEndOffset);
    const isARecord = query.qtype === 1; // Type A (IPv4)

    // 如果是 A 记录，返回 1 条 0.0.0.0 的 Answer (长度为 16 字节)
    // 如果是 AAAA 或 HTTPS(65) 等记录，返回 NXDOMAIN (Flags = 0x8183)，防止 IPv6/HTTP3 绕过
    const answerLength = isARecord ? 16 : 0;
    const dnsResponseLen = 12 + questionSection.length + answerLength;
    const dnsResponse = new Uint8Array(dnsResponseLen);

    // Transaction ID
    dnsResponse[0] = query.dnsPayload[0];
    dnsResponse[1] = query.dnsPayload[1];

    if (isARecord) {
      // Flags: 0x8180 (Standard query response, No error)
      dnsResponse[2] = 0x81;
      dnsResponse[3] = 0x80;
      // QDCOUNT = 1, ANCOUNT = 1
      dnsResponse[4] = 0x00;
      dnsResponse[5] = 0x01;
      dnsResponse[6] = 0x00;
      dnsResponse[7] = 0x01;
    } else {
      // Flags: 0x8183 (Standard query response, No such name / NXDOMAIN)
      dnsResponse[2] = 0x81;
      dnsResponse[3] = 0x83;
      // QDCOUNT = 1, ANCOUNT = 0
      dnsResponse[4] = 0x00;
      dnsResponse[5] = 0x01;
      dnsResponse[6] = 0x00;
      dnsResponse[7] = 0x00;
    }

    // NSCOUNT = 0, ARCOUNT = 0
    dnsResponse[8] = 0x00;
    dnsResponse[9] = 0x00;
    dnsResponse[10] = 0x00;
    dnsResponse[11] = 0x00;

    // 拷贝原始 Question 字段
    dnsResponse.set(questionSection, 12);

    if (isARecord) {
      const ansOffset = 12 + questionSection.length;
      // Name pointer to offset 12 (0xc00c)
      dnsResponse[ansOffset] = 0xc0;
      dnsResponse[ansOffset + 1] = 0x0c;
      // Type A (0x0001)
      dnsResponse[ansOffset + 2] = 0x00;
      dnsResponse[ansOffset + 3] = 0x01;
      // Class IN (0x0001)
      dnsResponse[ansOffset + 4] = 0x00;
      dnsResponse[ansOffset + 5] = 0x01;
      // TTL = 1 second (设置为 1 秒以便每次打开目标 App 都能实时触发并观察到拦截日志)
      dnsResponse[ansOffset + 6] = 0x00;
      dnsResponse[ansOffset + 7] = 0x00;
      dnsResponse[ansOffset + 8] = 0x00;
      dnsResponse[ansOffset + 9] = 0x01;
      // RDLENGTH = 4
      dnsResponse[ansOffset + 10] = 0x00;
      dnsResponse[ansOffset + 11] = 0x04;
      // RDATA = 0.0.0.0
      dnsResponse[ansOffset + 12] = 0x00;
      dnsResponse[ansOffset + 13] = 0x00;
      dnsResponse[ansOffset + 14] = 0x00;
      dnsResponse[ansOffset + 15] = 0x00;
    }

    return DnsPacketParser.wrapDnsResponseInIpv4Udp(query, dnsResponse);
  }

  /**
   * 将 DNS 响应负载封装为完整的 IPv4 + UDP 数据包（交换源目 IP 与端口，计算校验和）
   */
  public static wrapDnsResponseInIpv4Udp(query: ParsedDnsQuery, dnsResponsePayload: Uint8Array): Uint8Array {
    const ipHeaderLen = 20;
    const udpHeaderLen = 8;
    const udpTotalLen = udpHeaderLen + dnsResponsePayload.length;
    const ipTotalLen = ipHeaderLen + udpTotalLen;

    const packet = new Uint8Array(ipTotalLen);

    // 1. 构造 IPv4 Header (20 bytes)
    packet[0] = 0x45; // Version 4, IHL 5 (20 bytes)
    packet[1] = 0x00; // DSCP / ECN
    packet[2] = (ipTotalLen >> 8) & 0xff;
    packet[3] = ipTotalLen & 0xff;
    packet[4] = 0x00; // Identification
    packet[5] = 0x00;
    packet[6] = 0x40; // Flags: Don't Fragment
    packet[7] = 0x00;
    packet[8] = 64;   // TTL = 64
    packet[9] = 17;   // Protocol = UDP (17)
    packet[10] = 0x00; // Header Checksum (占位，稍后计算)
    packet[11] = 0x00;

    // 源 IP = 原请求的目标 IP (10.88.0.1)，目标 IP = 原请求的源 IP (10.88.0.2)
    packet.set(query.dstIp, 12);
    packet.set(query.srcIp, 16);

    // 计算 IPv4 首部校验和
    const checksum = DnsPacketParser.computeIpv4Checksum(packet, ipHeaderLen);
    packet[10] = (checksum >> 8) & 0xff;
    packet[11] = checksum & 0xff;

    // 2. 构造 UDP Header (8 bytes)
    packet[20] = (query.dstPort >> 8) & 0xff; // 源端口 = 53
    packet[21] = query.dstPort & 0xff;
    packet[22] = (query.srcPort >> 8) & 0xff; // 目标端口 = 客户端原随机端口
    packet[23] = query.srcPort & 0xff;
    packet[24] = (udpTotalLen >> 8) & 0xff;
    packet[25] = udpTotalLen & 0xff;
    // IPv4 下 UDP Checksum 设为 0x0000 表示可选不校验
    packet[26] = 0x00;
    packet[27] = 0x00;

    // 3. 填入 DNS 响应负载
    packet.set(dnsResponsePayload, 28);
    return packet;
  }

  /**
   * 计算标准 16 位反码求和的 IPv4 首部校验和
   */
  private static computeIpv4Checksum(header: Uint8Array, length: number): number {
    let sum = 0;
    for (let i = 0; i < length; i += 2) {
      const word = (header[i] << 8) | header[i + 1];
      sum += word;
    }
    while ((sum >> 16) > 0) {
      sum = (sum & 0xffff) + (sum >> 16);
    }
    return (~sum) & 0xffff;
  }

  /**
   * 计算 TCP 校验和（包含 12 字节 IPv4 伪首部）
   */
  private static computeTcpChecksum(srcIp: Uint8Array, dstIp: Uint8Array, tcpSegment: Uint8Array): number {
    let sum = 0;
    // 伪首部源目 IP
    sum += (srcIp[0] << 8) | srcIp[1];
    sum += (srcIp[2] << 8) | srcIp[3];
    sum += (dstIp[0] << 8) | dstIp[1];
    sum += (dstIp[2] << 8) | dstIp[3];
    // 协议号 (TCP = 6) + TCP 长度
    sum += 6;
    sum += tcpSegment.length;

    for (let i = 0; i < tcpSegment.length; i += 2) {
      const high = tcpSegment[i];
      const low = (i + 1 < tcpSegment.length) ? tcpSegment[i + 1] : 0;
      sum += (high << 8) | low;
    }
    while ((sum >> 16) > 0) {
      sum = (sum & 0xffff) + (sum >> 16);
    }
    return (~sum) & 0xffff;
  }
}
