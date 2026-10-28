import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { AdDomainRules } from '../main/ets/vpn/AdDomainRules';
import { DnsPacketParser } from '../main/ets/vpn/DnsPacketParser';

export default function localUnitTest() {
  describe('AdSkipVpnDnsUnitTest', () => {
    beforeAll(() => {
    });
    beforeEach(() => {
    });
    afterEach(() => {
    });
    afterAll(() => {
    });

    it('shouldMatchSplashAdDomainsAndAllowNormalDomains', 0, () => {
      expect(AdDomainRules.isBlocked('mi.gdt.qq.com')).assertEqual(true);
      expect(AdDomainRules.isBlocked('api.pangolin-sdk-toutiao.com')).assertEqual(true);
      expect(AdDomainRules.isBlocked('open.e.kuaishou.com')).assertEqual(true);
      expect(AdDomainRules.isBlocked('www.huawei.com')).assertEqual(false);
      expect(AdDomainRules.isBlocked('www.baidu.com')).assertEqual(false);
    });

    it('shouldParseIpv4DnsQueryAndBuildSinkholeResponse', 0, () => {
      // 构造发往 10.88.0.1:53 查询 mi.gdt.qq.com 的 IPv4+UDP+DNS 报文
      const domain = 'mi.gdt.qq.com';
      const labels = domain.split('.');
      let qnameLen = 1;
      for (const l of labels) {
        qnameLen += 1 + l.length;
      }
      const dnsLen = 12 + qnameLen + 4;
      const udpLen = 8 + dnsLen;
      const totalLen = 20 + udpLen;
      const pkt = new Uint8Array(totalLen);

      pkt[0] = 0x45;
      pkt[2] = (totalLen >> 8) & 0xff;
      pkt[3] = totalLen & 0xff;
      pkt[8] = 64;
      pkt[9] = 17;
      pkt.set([10, 88, 0, 2], 12);
      pkt.set([10, 88, 0, 1], 16);

      pkt[20] = (54321 >> 8) & 0xff;
      pkt[21] = 54321 & 0xff;
      pkt[22] = 0x00;
      pkt[23] = 53;
      pkt[24] = (udpLen >> 8) & 0xff;
      pkt[25] = udpLen & 0xff;

      pkt[28] = 0xab;
      pkt[29] = 0xcd;
      pkt[30] = 0x01;
      pkt[31] = 0x00;
      pkt[32] = 0x00;
      pkt[33] = 0x01;

      let pos = 40;
      for (const l of labels) {
        pkt[pos++] = l.length;
        for (let i = 0; i < l.length; i++) {
          pkt[pos++] = l.charCodeAt(i);
        }
      }
      pkt[pos++] = 0x00;
      pkt[pos++] = 0x00;
      pkt[pos++] = 0x01;
      pkt[pos++] = 0x00;
      pkt[pos++] = 0x01;

      const parsed = DnsPacketParser.parseIpv4DnsQuery(pkt, pkt.length);
      expect(parsed !== null).assertEqual(true);
      if (parsed !== null) {
        expect(parsed.domain).assertEqual('mi.gdt.qq.com');
        expect(parsed.qtype).assertEqual(1);
        const resp = DnsPacketParser.buildBlockedDnsResponsePacket(parsed);
        // 校验伪造响应包末尾 4 字节 RDATA 为 0.0.0.0
        expect(resp[resp.length - 4]).assertEqual(0);
        expect(resp[resp.length - 3]).assertEqual(0);
        expect(resp[resp.length - 2]).assertEqual(0);
        expect(resp[resp.length - 1]).assertEqual(0);
      }
    });
  });
}
