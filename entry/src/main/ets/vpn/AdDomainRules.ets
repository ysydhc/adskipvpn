import { fileIo } from '@kit.CoreFileKit';

/**
 * 国内主流 App 开屏广告与广告联盟核心域名规则库
 * 精简自 AWAvenue-Ads-Rule (秋风广告规则) 与 Anti-AD，并针对腾讯音乐(TME)/优量汇(GDT)专项增强
 */
export class AdDomainRules {
  private static readonly CUSTOM_RULES_FILE = '/custom_blocked_domains.txt';

  // 默认拦截的广告根域名 / 子域名后缀
  private static readonly DEFAULT_BLOCKED_SUFFIXES: string[] = [
    // 1. 腾讯音乐 (QQ音乐 / 酷狗 / 酷我) 专属广告与开屏域名 (TME Ads)
    'tmead.y.qq.com',
    'tmeadcomm.y.qq.com',
    'tmeadbak.y.qq.com',
    'ad.y.qq.com',
    'ad.qq.com',
    'adstats.tencentmusic.com',
    'ad.tencentmusic.com',
    'tmead.tencentmusic.com',
    'adclick.tencentmusic.com',
    'adexpo.tencentmusic.com',
    'adtrack.tencentmusic.com',
    'report.tencentmusic.com',
    'monitor.music.qq.com',
    'stat.y.qq.com',
    'stat6.y.qq.com',
    'ads.privacy.qq.com',
    'ads.service.kugou.com',
    'adserviceretry.kugou.com',

    // 2. 腾讯 - 优量汇 / 广点通 (GDT) & 腾讯系开屏广告配置与素材 SDK
    'gdt.qq.com',
    'mi.gdt.qq.com',
    'v.gdt.qq.com',
    'v2.gdt.qq.com',
    'c.gdt.qq.com',
    'ii.gdt.qq.com',
    'win.gdt.qq.com',
    'e.qq.com',
    'sdk.e.qq.com',
    'tangram.e.qq.com',
    'us.l.qq.com',
    'l.qq.com',
    'dp3.qq.com',
    'adsmind.gdtimg.com',
    'adsmind.ugdtimg.com',
    'pgdt.gtimg.cn',
    'pgdt.ugdtimg.com',
    'splash.qlive.qq.com',
    'oth.str.mdt.qq.com',
    'oth.eve.mdt.qq.com',
    'otheve.beacon.qq.com',
    'astrategy.beacon.qq.com',
    'tpstelemetry.tencent.com',
    'h.trace.qq.com',

    // 3. 字节跳动 - 穿山甲联盟 (Pangolin)
    'pglstatp-toutiao.com',
    'pangolin-sdk-toutiao.com',
    'pangolin-sdk-toutiao-b.com',
    'pangolin-sdk-toutiao1.com',
    'pangolin.snssdk.com',
    'ad.toutiao.com',
    'ad.zijieapi.com',
    'bds.snssdk.com',
    'dig.bdurl.net',

    // 4. 快手 - 磁力引擎 / 快手联盟
    'adukwai.com',
    'open.e.kuaishou.com',
    'gdfp.gifshow.com',
    'ad.partner.gifshow.com',

    // 5. 百度 - 百青藤联盟
    'pos.baidu.com',
    'cpro.baidu.com',
    'mobads.baidu.com',
    'mobads-logs.baidu.com',
    'als.baidu.com',
    'hmma.baidu.com',

    // 6. 阿里妈妈 / 高德 / UC 开屏广告
    'atanx.alicdn.com',
    'afp.alicdn.com',
    'optimus-ads.amap.com',
    'adashx.ut.taobao.com',

    // 7. 微博 / 网易云 / B站等常见开屏域名
    'sdkapp.uve.weibo.com',
    'alitui.weibo.com',
    'ad.music.163.com',
    'ad.bilibili.com',

    // 8. 本地自测专用域名
    'ad-test.example.com'
  ];

  // 用于诊断抓包时高亮标记的“重点关注可疑域名关键词”（与 QQ音乐、腾讯、广告、CDN 素材相关）
  private static readonly SUSPECT_KEYWORDS: string[] = [
    'qq.com',
    'tencent',
    'tme',
    'gtimg',
    'gdt',
    'qpic',
    'qlogo',
    'music',
    'kugou',
    'kuwo',
    'ad',
    'splash',
    'beacon',
    'trace',
    'stat',
    'mdt',
    'httpdns',
    'doh',
    'pangolin',
    'toutiao',
    'snssdk'
  ];

  private static customSuffixes: Set<string> = new Set<string>(
    AdDomainRules.DEFAULT_BLOCKED_SUFFIXES.map((s: string) => s.trim())
  );

  /**
   * 判断域名是否命中广告黑名单，并返回命中的具体规则名（未命中返回 null）
   */
  public static matchRule(domain: string): string | null {
    const clean = domain.trim().toLowerCase().replace(/\.$/, '');
    if (!clean) {
      return null;
    }
    for (const suffix of AdDomainRules.customSuffixes) {
      if (clean === suffix || clean.endsWith('.' + suffix)) {
        return suffix;
      }
    }
    return null;
  }

  /**
   * 判断域名是否命中广告黑名单
   */
  public static isBlocked(domain: string): boolean {
    return AdDomainRules.matchRule(domain) !== null;
  }

  /**
   * 判断未命中的域名是否属于需要重点监控的“可疑关联域名”（如 QQ音乐业务/素材/统计域名）
   */
  public static isSuspectDomain(domain: string): boolean {
    const clean = domain.trim().toLowerCase();
    for (const kw of AdDomainRules.SUSPECT_KEYWORDS) {
      if (clean.includes(kw)) {
        return true;
      }
    }
    return false;
  }

  /**
   * 添加自定义拦截域名后缀（支持持久化到应用沙箱目录，供 UI 与 :vpn 跨进程共享）
   */
  public static addRule(domainSuffix: string, filesDir?: string): void {
    const clean = domainSuffix.trim().toLowerCase().replace(/\.$/, '');
    if (clean.length === 0) {
      return;
    }
    AdDomainRules.customSuffixes.add(clean);
    if (filesDir) {
      try {
        const path = filesDir + AdDomainRules.CUSTOM_RULES_FILE;
        const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND);
        fileIo.writeSync(file.fd, `${clean}\n`);
        fileIo.closeSync(file);
      } catch (_) {
      }
    }
  }

  /**
   * 从应用沙箱目录同步加载用户追加的自定义规则
   */
  public static syncCustomRulesFromDisk(filesDir: string): number {
    let added = 0;
    try {
      const path = filesDir + AdDomainRules.CUSTOM_RULES_FILE;
      if (!fileIo.accessSync(path)) {
        return 0;
      }
      const content = fileIo.readTextSync(path);
      const lines = content.split('\n');
      for (const line of lines) {
        const clean = line.trim().toLowerCase().replace(/\.$/, '');
        if (clean.length > 0 && !AdDomainRules.customSuffixes.has(clean)) {
          AdDomainRules.customSuffixes.add(clean);
          added++;
        }
      }
    } catch (_) {
    }
    return added;
  }

  /**
   * 获取当前所有规则列表
   */
  public static getAllRules(): string[] {
    return Array.from(AdDomainRules.customSuffixes);
  }
}
