// ============================================================================
// page-markdown.js —— 把渲染后的 DOM 转成 Markdown
//
// 为什么放在扩展里：只有浏览器手上有「渲染后」的 DOM。SPA、懒加载、登录后才可见的
// 内容，后端拿 URL 去抓是抓不到的。后端只负责在这份 Markdown 上做 Agent。
//
// 运行环境约束：
//   - 普通脚本，不是 ES module，没有构建步骤，不允许任何外部依赖；
//   - 跑在 MV3 content script 的隔离世界里，可能被重复注入（下面有幂等守卫）；
//   - 同步返回，且大页面上不能长时间卡住主线程（见 tick() 的软预算降级）。
//
// 对外契约（docs/protocol.md「扩展内部契约」，不可改）：
//   window.__webchatMarkdown.extract(options?)
//     → { url, title, markdown, truncated, stats: { chars, images, links, headings } }
//
// 整体流水线：
//   pickRoot()       正文容器选取（站点规则 → 文档站 → 语义标签 → 打分 → body）
//   shouldDrop()     逐节点剔除（脚本 / 隐藏 / 广告 / 导航…）
//   renderChildren() 节点 → Markdown 块（块级、行内两条路径）
//   postProcess()    空白归一、重复链接收敛
//   truncate()       按 maxChars 从尾部安全截断
//
// beamai_muse 的改动（2026-10-27）：内容本身就是导航的页面（维基百科门户页
// 全部语言链接都在 <nav> 里）第一遍几乎什么都剩不下，见 extract() 里的
// 「导航页第二遍」：结果过短而页面可见文字多得多时，整页重抽一遍并保留导航。
// ============================================================================

if (!window.__webchatMarkdown) {
  (function () {
    'use strict';

    // ---------------------------------------------------------------- 常量

    var VERSION = '1.0.0';

    var DEFAULTS = {
      // 20 万字符已经远超任何模型的单次上下文；真正的长文控制在后端
      // （超过 InlinePageChars 就走 page_read 工具），这里的上限只是防止
      // 把一个失控的页面整个搬进内存和消息通道。
      maxChars: 200000,
      // 软预算：超过就降级，不是硬超时。给 500ms 是因为用户点了悬浮球在等，
      // 超过半秒的卡顿肉眼可见。
      budgetMs: 500
    };

    // 整棵子树直接丢弃的标签。
    // picture / math / pre / code / table 不在这里，它们有专门的处理。
    var DROP_TAGS = new Set([
      'script', 'style', 'noscript', 'template', 'link', 'meta', 'base', 'head', 'title',
      'iframe', 'frame', 'frameset', 'object', 'embed', 'applet', 'canvas', 'portal',
      // svg 绝大多数是图标和装饰，少数是图表但也没有可用的文本表示，整体丢弃
      'svg',
      // 多媒体：没有文本价值，source/track 一并带走
      'audio', 'video', 'track',
      // 表单控件：值不是页面「内容」，而且 textarea 里可能塞着几十 KB 的隐藏数据
      'input', 'select', 'textarea', 'button', 'option', 'optgroup', 'datalist',
      'progress', 'meter',
      // 模态框和弹层
      'dialog'
    ]);

    // 按块级排版的标签。div/section 之类容器也算块级，
    // 这样「一堆 div 当段落用」的页面不会被拼成一行。
    var BLOCK_TAGS = new Set([
      'address', 'article', 'aside', 'blockquote', 'caption', 'center', 'dd', 'details',
      'div', 'dl', 'dt', 'fieldset', 'figcaption', 'figure', 'footer', 'form', 'h1', 'h2',
      'h3', 'h4', 'h5', 'h6', 'header', 'hgroup', 'hr', 'legend', 'li', 'main', 'menu',
      'nav', 'ol', 'p', 'pre', 'section', 'summary', 'table', 'tbody', 'td', 'tfoot', 'th',
      'thead', 'tr', 'ul'
    ]);

    // ARIA 角色层面的非正文区域
    var DROP_ROLES = new Set([
      'navigation', 'banner', 'contentinfo', 'complementary', 'search', 'dialog',
      'alertdialog', 'tooltip', 'menu', 'menubar', 'toolbar', 'tablist', 'alert',
      'status', 'log', 'marquee', 'timer'
    ]);

    // 广告、推荐位、功能区的 class / id 特征词。
    // 用「分隔符包围」的方式匹配，避免 read / upload / download 里的 ad 被误伤。
    // 这里刻意**没有** header：文章内部的 .post-header 往往正是标题所在。
    var NOISE_TOKENS = [
      'ad', 'ads', 'adv', 'advert', 'adverts', 'advertising', 'advertisement', 'adslot',
      'adbox', 'adbanner', 'adsbygoogle', 'google-ad', 'doubleclick', 'taboola', 'outbrain',
      'banner', 'sponsor', 'sponsored', 'promo', 'promotion', 'popup', 'modal', 'overlay',
      'lightbox', 'cookie', 'cookies', 'gdpr', 'consent', 'newsletter', 'subscribe',
      'subscription', 'paywall', 'share', 'shares', 'sharing', 'social', 'socialbar',
      'breadcrumb', 'breadcrumbs', 'pagination', 'pager', 'related', 'relateds',
      'recommend', 'recommended', 'recommendation', 'recommendations', 'recirc',
      'trending', 'sidebar', 'widget', 'widgets', 'toolbar', 'skip-link', 'skiplink',
      'back-to-top', 'gotop', 'comment', 'comments', 'disqus', 'livefyre', 'gitalk',
      'utterances', 'nav', 'navbar', 'navigation', 'masthead', 'copyright', 'footer',
      'sitemap', 'toc', 'anchor-nav', 'qrcode', 'noprint', 'hidden-print', 'print-only'
    ];
    var NOISE_RE = new RegExp(
      '(?:^|[\\s_\\-\\.])(' + NOISE_TOKENS.join('|') + ')(?:$|[\\s_\\-\\.]|\\d)', 'i'
    );

    // 「导航页第二遍」（ctx.keepNav）保留的导航：标签、角色和 class 特征词。
    // 其余噪音（广告、页脚、侧栏、弹层、隐藏元素……）照旧丢。
    var NAV_ROLES = new Set(['navigation', 'menu', 'menubar']);
    var NAV_TOKEN_RE = /(?:^|[\s_\-\.])(nav|navbar|navigation|menu)(?=$|[\s_\-\.]|\d)/ig;

    // 扩展自己注入的 UI。不剔除的话，用户问一次，
    // 上一轮的回答就会被当成「页面内容」再喂回去一次。
    var SELF_ID_RE = /^(ai-assistant|webchat)/i;
    var SELF_CLASS_RE = /(^|\s)(ball-container|dialog-overlay|ai-assistant[\w-]*)(\s|$)/;

    // readability 打分用的正负特征词
    var POSITIVE_RE = /(^|[\s_-])(article|body|content|entry|hentry|main|page|post|text|blog|story|column|markdown|prose|answer|question|detail)([\s_-]|$)/i;
    var NEGATIVE_RE = /(^|[\s_-])(combx|comment|contact|foot|footer|footnote|masthead|media|meta|outbrain|promo|related|scroll|shoutbox|sidebar|sponsor|shopping|tags|tool|widget|nav|menu|banner|ad|ads|advert|social|share|popup|modal|hidden)([\s_-]|$)/i;

    // 常见文档站的正文容器（VuePress / VitePress / Docusaurus / MkDocs / Sphinx /
    // GitBook / Docsify）。这些站点的 <main> 往往把侧边栏和目录一起包进去，
    // 直接用 main 会带一大堆导航噪音，所以要比语义标签更早试。
    var DOC_SELECTORS = [
      '.theme-default-content',          // VuePress
      '.vp-doc',                         // VitePress
      '.theme-doc-markdown',             // Docusaurus v2 / v3
      '.md-content__inner',              // MkDocs Material
      '.rst-content .document',          // Sphinx / ReadTheDocs
      '.markdown-section',               // Docsify
      '.markdown-body',                  // GitHub 风格渲染容器，很多静态站也在用
      '.book-body .page-inner section'   // GitBook
    ];

    // 站点特例。做不到「完美」，目标只是「不要退化成一坨」。
    var SITE_RULES = [
      { host: /(^|\.)github\.com$/i, sel: ['article.markdown-body', '#readme .markdown-body', '#readme', '[data-testid="issue-body"]', '.repository-content'] },
      { host: /(^|\.)zhihu\.com$/i, sel: ['.Post-RichTextContainer', '.QuestionAnswer-content', '.RichText', '.Post-Main'] },
      { host: /(^|\.)mp\.weixin\.qq\.com$/i, sel: ['#js_content', '#img-content'] },
      { host: /(^|\.)juejin\.cn$/i, sel: ['#article-root', '.markdown-body', '.article-viewer'] },
      { host: /(^|\.)csdn\.net$/i, sel: ['#content_views', '.blog-content-box'] },
      { host: /(^|\.)cnblogs\.com$/i, sel: ['#cnblogs_post_body', '#post_detail'] },
      { host: /(^|\.)jianshu\.com$/i, sel: ['article', '.show-content'] },
      { host: /(^|\.)segmentfault\.com$/i, sel: ['.article__content', 'article'] },
      { host: /(^|\.)wikipedia\.org$/i, sel: ['#mw-content-text .mw-parser-output', '#mw-content-text'] },
      { host: /(^|\.)developer\.mozilla\.org$/i, sel: ['article.main-page-content', '.main-page-content'] },
      { host: /(^|\.)(stackoverflow|stackexchange|superuser|serverfault)\.com$/i, sel: ['#mainbar'] },
      { host: /(^|\.)medium\.com$/i, sel: ['article'] }
    ];

    // 语法高亮插件插进来的行号槽。不摘掉的话代码块每行都会多出一个数字。
    var LINENO_SELECTOR = [
      '.line-numbers-rows',                 // Prism line-numbers
      '.linenos', '.lineno', '.linenodiv',  // Pygments
      '.gutter',                            // SyntaxHighlighter
      '.hljs-ln-numbers',                   // highlight.js line numbers
      '.code-line-numbers',
      '.blob-num'                           // GitHub 旧版代码视图
    ].join(',');

    // ---------------------------------------------------------------- 小工具

    function now() {
      return (window.performance && performance.now) ? performance.now() : Date.now();
    }

    /** 任何来源不明的值都从这里过一遍，杜绝 undefined / [object Object] 漏进 Markdown。 */
    function str(v) {
      return (typeof v === 'string') ? v : (v == null ? '' : String(v));
    }

    function attr(el, name) {
      try { return str(el.getAttribute(name)); } catch (e) { return ''; }
    }

    function tagOf(el) {
      var t = el && el.tagName;
      return t ? String(t).toLowerCase() : '';
    }

    /** class 用 getAttribute 读：SVG 元素的 el.className 是对象，不是字符串。 */
    function classOf(el) {
      return attr(el, 'class');
    }

    function num(v, dflt) {
      var n = Number(v);
      return (isFinite(n) && n > 0) ? n : dflt;
    }

    function textLen(el) {
      try { return el.textContent ? el.textContent.length : 0; } catch (e) { return 0; }
    }

    function blk(kind, text) {
      return { k: kind, t: str(text) };
    }

    function joinBlocks(list) {
      var out = [];
      for (var i = 0; i < list.length; i++) {
        if (list[i] && list[i].t) out.push(list[i].t);
      }
      return out.join('\n\n');
    }

    /**
     * 列表项内部的块拼接：紧跟在段落后面的嵌套列表不空行，
     * 否则 Markdown 渲染器会把它当成「松散列表」，每一项都套一层 <p>。
     */
    function joinItemBlocks(list) {
      var s = '';
      for (var i = 0; i < list.length; i++) {
        var b = list[i];
        if (!b || !b.t) continue;
        if (!s) { s = b.t; continue; }
        s += (b.k === 'list' ? '\n' : '\n\n') + b.t;
      }
      return s;
    }

    /** 行内片段收尾：折叠空白，但保留 <br> 产生的显式换行。 */
    function tidyInline(s) {
      if (!s) return '';
      return s
        .replace(/[ \t]+/g, ' ')
        .replace(/ *\n */g, '\n')
        .replace(/\n{3,}/g, '\n\n')
        .trim();
    }

    // ---------------------------------------------------------------- URL 处理

    /** 相对路径 → 绝对 URL。协议不安全或解析失败一律返回空串，调用方降级为纯文本。 */
    function absUrl(raw) {
      var s = str(raw).trim();
      if (!s) return '';
      // 只看原始字符串的协议：src="img/a.png" 这种没有协议前缀的要放行
      if (/^\s*(javascript|vbscript|about)\s*:/i.test(s)) return '';
      try {
        var u = new URL(s, document.baseURI);
        if (u.protocol === 'javascript:' || u.protocol === 'about:') return '';
        return u.href;
      } catch (e) {
        return '';
      }
    }

    function isDataUri(s) {
      return /^\s*data:/i.test(str(s));
    }

    /** 当前页 URL（去掉 hash），用来识别「写成绝对形式的页内锚点」。 */
    function pageUrlNoHash() {
      try {
        var u = new URL(document.baseURI);
        u.hash = '';
        return u.href;
      } catch (e) {
        return '';
      }
    }

    function stripHash(href) {
      var i = href.indexOf('#');
      return i < 0 ? href : href.slice(0, i);
    }

    /** 放进 Markdown 圆括号里的 URL：空格转义，含括号的改用 <> 包裹。 */
    function mdUrl(u) {
      var s = str(u).replace(/\s/g, '%20');
      if (s.indexOf('(') >= 0 || s.indexOf(')') >= 0) {
        return '<' + s.replace(/</g, '%3C').replace(/>/g, '%3E') + '>';
      }
      return s;
    }

    /**
     * srcset → 挑最大的一张。
     * 描述符可能是 2x 也可能是 1200w；w 的数值天然比 x 大几个量级，
     * 把 x 乘 1000 拉到同一量级后直接比数值即可。
     */
    function pickFromSrcset(srcset) {
      var s = str(srcset).trim();
      if (!s) return '';
      var best = '', bestScore = -1;
      var parts = s.split(',');
      for (var i = 0; i < parts.length; i++) {
        var seg = parts[i].trim();
        if (!seg) continue;
        var bits = seg.split(/\s+/);
        var url = bits[0];
        if (!url) continue;
        var score = 1;
        for (var j = 1; j < bits.length; j++) {
          var m = /^([\d.]+)([wx])$/.exec(bits[j]);
          if (m) score = m[2] === 'w' ? parseFloat(m[1]) : parseFloat(m[1]) * 1000;
        }
        if (score > bestScore) { bestScore = score; best = url; }
      }
      return best;
    }

    // 懒加载属性名。顺序无所谓，下面按「真实 URL 优先于 data: 占位图」重排。
    var LAZY_ATTRS = [
      'data-src', 'data-original', 'data-actualsrc', 'data-lazy-src', 'data-lazy',
      'data-echo', 'data-url', 'data-image', 'data-original-src', 'data-hi-res-src',
      'data-real-src', 'data-defer-src', 'data-srcset'
    ];

    /**
     * 选出 <img> 真正该用的地址。
     * 懒加载图的 src 常常是 1x1 的 data: 占位图，真实地址藏在 data-* 里
     * （知乎 data-actualsrc、微信 data-src、各种 lazyload 插件 data-original），
     * 所以把候选分成「真实 URL」和「data: 占位」两桶，真实的优先。
     */
    function pickImageSrc(el) {
      var real = [], data = [];
      var push = function (v) {
        var s = str(v).trim();
        if (!s) return;
        (isDataUri(s) ? data : real).push(s);
      };

      try { if (el.currentSrc) push(el.currentSrc); } catch (e) { /* 忽略 */ }
      push(attr(el, 'src'));
      for (var i = 0; i < LAZY_ATTRS.length; i++) {
        var v = attr(el, LAZY_ATTRS[i]);
        if (!v) continue;
        push(LAZY_ATTRS[i] === 'data-srcset' ? pickFromSrcset(v) : v);
      }
      push(pickFromSrcset(attr(el, 'srcset')));

      // <picture><source srcset=...><img></picture>：img 自己可能只有兜底小图
      var pic = el.parentElement;
      if (pic && tagOf(pic) === 'picture') {
        var sources = pic.getElementsByTagName('source');
        for (var k = 0; k < sources.length; k++) {
          push(pickFromSrcset(attr(sources[k], 'srcset') || attr(sources[k], 'data-srcset')));
        }
      }

      return real.length ? real[0] : (data.length ? data[0] : '');
    }

    // ---------------------------------------------------------------- 预算与降级

    /**
     * 每访问 512 个节点检查一次时间预算：
     *   stage 0  完整模式
     *   stage 1  跳过 getComputedStyle / getBoundingClientRect（walk 里最贵的部分）
     *   stage 2  停止遍历，已产出的部分照常返回（标记为 truncated）
     */
    function tick(ctx) {
      ctx.nodes++;
      if ((ctx.nodes & 511) !== 0) return;
      if (ctx.nodes > 400000) { ctx.stage = 2; ctx.degraded = 'aborted'; return; }
      var dt = now() - ctx.t0;
      if (ctx.stage === 0 && dt > ctx.budgetMs) {
        ctx.stage = 1;
        ctx.degraded = 'fast';
      } else if (ctx.stage === 1 && dt > ctx.budgetMs * 4) {
        ctx.stage = 2;
        ctx.degraded = 'aborted';
      }
    }

    // ---------------------------------------------------------------- 可见性

    function computed(el, ctx) {
      var c = ctx.styles.get(el);
      if (c) return c;
      try {
        c = window.getComputedStyle(el);
      } catch (e) {
        c = null;
      }
      if (c) ctx.styles.set(el, c);
      return c;
    }

    /**
     * 元素是否「对用户不可见」。
     *
     * visibility 有个坑：微信公众号的 #js_content 在正文脚本跑完前带着
     * visibility:hidden，而 visibility 是继承的 —— 若按继承值判断，整篇正文
     * 都会被判成隐藏。所以只在「这个元素自己引入了 hidden」时才丢；继承来的不算
     * （真正引入 hidden 的祖先如果被访问到，自然会在它那一层被丢掉）。
     */
    function isHidden(el, ctx) {
      var cs = computed(el, ctx);
      if (!cs) return false;
      if (cs.display === 'none') return true;

      if (cs.visibility === 'hidden' || cs.visibility === 'collapse') {
        var p = el.parentElement;
        var pcs = p ? computed(p, ctx) : null;
        var inherited = !!pcs && (pcs.visibility === 'hidden' || pcs.visibility === 'collapse');
        if (!inherited) return true;
      }

      // 尺寸为 0：多半是撑高度的空 div、埋点像素、被折叠的占位。
      // childElementCount 做门槛，避免对超大子树白算一次 textContent。
      if (el.childElementCount < 8) {
        var r;
        try { r = el.getBoundingClientRect(); } catch (e) { r = null; }
        if (r && r.width === 0 && r.height === 0) {
          var t = el.textContent;
          if ((!t || !t.trim()) && !el.querySelector('img')) return true;
        }
      }
      return false;
    }

    /** class/id 命中广告特征词、且体量不大。「体量不大」这条是防止误伤正文。 */
    function isNoise(el, ctx) {
      var sig = classOf(el) + ' ' + attr(el, 'id') + ' ' + attr(el, 'data-testid');
      if (ctx.keepNav) sig = sig.replace(NAV_TOKEN_RE, ' ');
      if (!sig.trim()) return false;
      if (!NOISE_RE.test(sig)) return false;
      // 论坛页的 .comments、文档站的 .content-wrapper 都会命中特征词，
      // 但它们装着全页大部分文字，显然是正文，放行。
      return textLen(el) < ctx.noiseGuard;
    }

    function shouldDrop(el, tag, ctx) {
      if (ctx.skip.has(el)) return true;
      if (DROP_TAGS.has(tag)) return true;
      if (el === ctx.root) return false;

      // 扩展自己的悬浮球和对话框
      if (SELF_ID_RE.test(attr(el, 'id'))) return true;
      if (SELF_CLASS_RE.test(classOf(el))) return true;
      if (el.hasAttribute('data-webchat')) return true;

      if (el.hasAttribute('hidden')) return true;
      if (attr(el, 'aria-hidden') === 'true') return true;

      var role = attr(el, 'role').toLowerCase();
      if (role && DROP_ROLES.has(role) && !(ctx.keepNav && NAV_ROLES.has(role))) return true;

      // nav/aside/footer 一律丢（导航页第二遍保留 nav）。
      // header 只在「没找到正文容器、退回 body」时丢：正文容器内部的 <header>
      // 通常正是文章标题加作者行，丢了会把 h1 一起带走。
      if ((tag === 'nav' && !ctx.keepNav) || tag === 'aside' || tag === 'footer') return true;
      if (tag === 'header' && ctx.dropHeader) return true;

      if (isNoise(el, ctx)) return true;

      if (ctx.stage === 0 && isHidden(el, ctx)) return true;

      return false;
    }

    // ---------------------------------------------------------------- 正文选取

    function firstMatch(scope, selectors) {
      for (var i = 0; i < selectors.length; i++) {
        var el;
        try { el = scope.querySelector(selectors[i]); } catch (e) { el = null; }
        // 太短的容器多半是空壳（骨架屏、占位），不算数
        if (el && textLen(el) >= 120) return el;
      }
      return null;
    }

    function siteRoot(scope) {
      var host = '';
      try { host = location.hostname || ''; } catch (e) { host = ''; }
      if (!host) return null;
      for (var i = 0; i < SITE_RULES.length; i++) {
        if (SITE_RULES[i].host.test(host)) {
          var el = firstMatch(scope, SITE_RULES[i].sel);
          if (el) return el;
        }
      }
      return null;
    }

    function linkDensity(el) {
      var total = textLen(el);
      if (!total) return 1;
      var links = 0;
      var as = el.getElementsByTagName('a');
      for (var i = 0; i < as.length; i++) links += textLen(as[i]);
      return Math.min(1, links / total);
    }

    /**
     * readability 式打分：段落把分数往上传给父和祖父，再按链接密度、class 特征词修正。
     * 只在站点规则和语义标签都找不到正文时才走这条路。
     */
    function scoreRoot(scope) {
      var scores = new Map();
      var add = function (el, s) {
        if (!el || el.nodeType !== 1) return;
        var t = tagOf(el);
        if (t === 'body' || t === 'html') return;
        scores.set(el, (scores.get(el) || 0) + s);
      };

      var paras;
      try { paras = scope.querySelectorAll('p, pre, blockquote, dd, td'); } catch (e) { return null; }
      for (var i = 0; i < paras.length; i++) {
        var p = paras[i];
        var text = p.textContent ? p.textContent.trim() : '';
        if (text.length < 25) continue;
        // 标点数量是「这是自然语言，而不是一串按钮文字」的廉价信号
        var puncts = (text.match(/[,，、。；;！!？?]/g) || []).length;
        var base = 1 + Math.min(3, Math.floor(text.length / 100)) + Math.min(3, puncts);
        var anc = p.parentElement, level = 0;
        while (anc && level < 4) {
          add(anc, level === 0 ? base : base / (level * 2));
          anc = anc.parentElement;
          level++;
        }
      }
      if (!scores.size) return null;

      // 先按原始分取前 30 名，再算链接密度：linkDensity 是 O(子树)，
      // 对所有候选都算会退化成 O(n²)。
      var cands = [];
      scores.forEach(function (v, k) { cands.push([k, v]); });
      cands.sort(function (a, b) { return b[1] - a[1]; });
      cands = cands.slice(0, 30);

      var best = null, bestScore = 0;
      for (var j = 0; j < cands.length; j++) {
        var el = cands[j][0];
        var s = cands[j][1];
        var sig = classOf(el) + ' ' + attr(el, 'id');
        if (POSITIVE_RE.test(sig)) s += 25;
        if (NEGATIVE_RE.test(sig)) s -= 25;
        s = s * (1 - linkDensity(el));
        if (s > bestScore) { bestScore = s; best = el; }
      }
      if (!best || bestScore < 12 || textLen(best) < 200) return null;

      // 正文被拆在若干兄弟 div 里时，最高分往往只落在其中一块上。
      // 父节点体量明显更大、又不带负面特征词，就往上提一层。
      var parent = best.parentElement;
      if (parent && tagOf(parent) !== 'body' && tagOf(parent) !== 'html') {
        var psig = classOf(parent) + ' ' + attr(parent, 'id');
        if (!NEGATIVE_RE.test(psig) && textLen(best) < textLen(parent) * 0.5 &&
            (scores.get(parent) || 0) >= bestScore * 0.4) {
          best = parent;
        }
      }
      return best;
    }

    /**
     * 选正文容器。scope 是搜索范围（正常是 document.body，测试时可以传任意元素）。
     * 返回 { el, how }，how 只是给 stats 看的诊断信息。
     */
    function pickRoot(scope) {
      var fallback = { el: scope, how: 'body' };
      if (!scope) return fallback;

      try {
        var site = siteRoot(scope);
        if (site) return { el: site, how: 'site' };

        var doc = firstMatch(scope, DOC_SELECTORS);
        if (doc) return { el: doc, how: 'docsite' };

        // 语义标签
        var sem = [];
        var list = scope.querySelectorAll('article, main, [role="main"]');
        for (var i = 0; i < list.length; i++) {
          sem.push({ el: list[i], len: textLen(list[i]), tag: tagOf(list[i]) });
        }
        if (sem.length) {
          var bodyLen = textLen(scope) || 1;
          sem.sort(function (a, b) { return b.len - a.len; });
          var top = sem[0];

          // 列表页：一堆 <article> 卡片，最大的那张也只占全页一小块，别用它
          var articleCount = 0;
          for (var k = 0; k < sem.length; k++) if (sem[k].tag === 'article') articleCount++;
          var cardish = articleCount >= 3 && top.len < bodyLen * 0.3;

          if (!cardish && top.len >= 200) {
            // <main> 常常把侧栏一起包进去；同量级的 <article> 更精准，优先
            for (var m = 0; m < sem.length; m++) {
              if (sem[m].tag === 'article' && sem[m].len >= top.len * 0.6) { top = sem[m]; break; }
            }
            return { el: top.el, how: 'semantic:' + top.tag };
          }
        }

        var scored = scoreRoot(scope);
        if (scored) return { el: scored, how: 'scored' };
      } catch (e) {
        // 选取失败不该让整个抽取失败，退回 body 就是了
      }
      return fallback;
    }

    // ---------------------------------------------------------------- 文本与转义

    /**
     * 文本节点 → Markdown 行内文本。
     *
     * 转义策略刻意保守：这份 Markdown 是给模型读的，满屏反斜杠比偶尔一个
     * 失效的强调更糟。只转义会真正破坏结构的东西：
     *   - 行首的块级标记（#、>、-、1. …）—— 只有该文本正好在行首时才转
     *   - 看起来像 HTML 标签的 <xxx
     *   - 反引号（会误开行内代码）
     *   - 表格里的 |、链接文字里的 []
     * snake_case 里的下划线、数学式里的 * 一律不转义。
     */
    function renderText(node, ctx, atLineStart) {
      var t = node.nodeValue;
      if (!t) return '';
      // &nbsp; 和窄空格统一成普通空格；零宽字符直接删掉（复制粘贴的隐形垃圾）
      t = t.replace(/[\u00a0\u2007\u202f]/g, ' ').replace(/[\u200b-\u200d\ufeff]/g, '');
      // 常规 white-space 下换行等价于空格
      t = t.replace(/[\t\f\r]/g, ' ').replace(/\s*\n\s*/g, ' ').replace(/ {2,}/g, ' ');
      if (!t) return '';

      t = t.replace(/`/g, '\\`').replace(/<(?=[a-zA-Z/!?])/g, '\\<');
      if (ctx.inTable) t = t.replace(/\|/g, '\\|');
      if (ctx.inLink) t = t.replace(/([[\]])/g, '\\$1');
      if (atLineStart) t = t.replace(/^(\s*)(#{1,6}\s|>|[-+*]\s|\d{1,9}[.)]\s)/, '$1\\$2');
      return t;
    }

    // ---------------------------------------------------------------- 行内渲染

    /** 行内上下文里逐个子节点拼接。块级子元素在这里被摊平成一行。 */
    function renderInlineChildren(el, ctx) {
      var out = '';
      var kids = el.childNodes;
      for (var i = 0; i < kids.length; i++) {
        if (ctx.stage >= 2) break;
        var node = kids[i];
        if (node.nodeType === 3) { out += renderText(node, ctx, out === ''); continue; }
        if (node.nodeType !== 1) continue;
        tick(ctx);
        var tag = tagOf(node);
        if (shouldDrop(node, tag, ctx)) continue;
        var piece = renderInline(node, tag, ctx);
        // 摊平块级元素时补个空格，免得 "第一行第二行" 粘在一起
        if (piece && BLOCK_TAGS.has(tag) && out && !/\s$/.test(out)) out += ' ';
        out += piece;
      }
      return out;
    }

    /** 行内代码：内容里有反引号时用更多反引号包起来。 */
    function codeSpan(text) {
      var t = str(text).replace(/\s+/g, ' ').trim();
      if (!t) return '';
      var runs = t.match(/`+/g) || [];
      var longest = 0;
      for (var i = 0; i < runs.length; i++) longest = Math.max(longest, runs[i].length);
      var fence = new Array(longest + 2).join('`');
      var pad = (t.charAt(0) === '`' || t.charAt(t.length - 1) === '`') ? ' ' : '';
      return fence + pad + t + pad + fence;
    }

    /**
     * 强调类包裹。两个坑：
     *   1. Markdown 的 ** 不能包住首尾空白，否则不生效 —— 把空白挤到外面；
     *   2. 嵌套同种强调会产生 ****，用 ctx 上的深度标记避免。
     */
    function wrapEmphasis(el, ctx, mark, flag) {
      if (ctx[flag]) return renderInlineChildren(el, ctx);
      ctx[flag] = true;
      var inner = renderInlineChildren(el, ctx);
      ctx[flag] = false;
      var m = /^(\s*)([\s\S]*?)(\s*)$/.exec(inner);
      if (!m || !m[2]) return inner;
      return m[1] + mark + m[2] + mark + m[3];
    }

    /** MathML：优先取 TeX 注解，取不到就用纯文本（拼出来的公式通常没法看，如实降级）。 */
    function renderMath(el, ctx) {
      var ann = el.querySelector('annotation[encoding*="tex" i], annotation[encoding*="TeX"]');
      var tex = ann ? str(ann.textContent).trim() : '';
      if (tex) return '$' + tex.replace(/\s+/g, ' ') + '$';
      return str(el.textContent).replace(/\s+/g, ' ').trim();
    }

    function isTinyImage(el, ctx) {
      var w = parseInt(attr(el, 'width'), 10);
      var h = parseInt(attr(el, 'height'), 10);
      if (isFinite(w) && isFinite(h) && w > 0 && h > 0 && w <= 32 && h <= 32) return true;
      if (ctx.stage === 0) {
        var r;
        try { r = el.getBoundingClientRect(); } catch (e) { r = null; }
        if (r && r.width > 0 && r.height > 0 && r.width <= 32 && r.height <= 32) return true;
      }
      return false;
    }

    /**
     * <img> → ![alt](绝对URL)
     *   - data: URI 一律不落地址（几百 KB base64 塞进提示词是灾难）；
     *     alt 非空时留一个 ![alt](inline-image) 占位，让模型知道「这里有张图，内容是…」，
     *     alt 为空则整个丢掉。
     *   - alt 为空且尺寸很小 → 装饰性图标，丢。
     */
    function renderImage(el, ctx) {
      var alt = str(attr(el, 'alt') || attr(el, 'title') || attr(el, 'aria-label'))
        .replace(/\s+/g, ' ').trim().replace(/([[\]])/g, '\\$1');
      var raw = pickImageSrc(el);
      if (!raw) return alt ? '' : '';

      if (isDataUri(raw)) {
        ctx.images++;
        return alt ? '![' + alt + '](inline-image)' : '';
      }
      if (!alt && (isTinyImage(el, ctx) || /(spacer|blank|pixel|1x1|transparent|placeholder)\.(gif|png|svg)/i.test(raw))) {
        return '';
      }
      var url = absUrl(raw);
      if (!url) return '';
      ctx.images++;
      return '![' + alt + '](' + mdUrl(url) + ')';
    }

    /**
     * <a href> → [文本](绝对URL)
     * 页内锚点和 javascript: 只留文本 —— 后端拿这些地址什么也做不了，
     * 留着只会诱导模型去「访问」一个不存在的页面。
     */
    function renderAnchor(el, ctx) {
      var prevLink = ctx.inLink;
      ctx.inLink = true;
      var text = renderInlineChildren(el, ctx);
      ctx.inLink = prevLink;
      text = text.replace(/\s+/g, ' ').trim();

      var href = attr(el, 'href');
      if (!text) {
        // 空文本的锚点：可能是「跳到本节」的小图标，直接丢
        return '';
      }
      if (!href || href.charAt(0) === '#') return text;

      var url = absUrl(href);
      if (!url) return text;
      // 写成绝对形式的页内锚点也只留文本
      if (url.indexOf('#') >= 0 && stripHash(url) === ctx.pageUrl) return text;
      if (isDataUri(url) || /^blob:/i.test(url)) return text;

      ctx.links++;
      return '[' + text + '](' + mdUrl(url) + ')';
    }

    function renderInline(el, tag, ctx) {
      switch (tag) {
        case 'br': return '\n';
        case 'wbr': return '';
        case 'img': return renderImage(el, ctx);
        case 'a': return renderAnchor(el, ctx);
        case 'code':
          // <pre><code> 已经在 renderPre 里整块处理，这里只管行内的
          return ctx.inCode ? renderInlineChildren(el, ctx) : codeSpan(el.textContent);
        case 'kbd': case 'samp': case 'var': case 'tt':
          return codeSpan(el.textContent);
        case 'strong': case 'b':
          return wrapEmphasis(el, ctx, '**', 'inStrong');
        case 'em': case 'i': case 'cite': case 'dfn':
          return wrapEmphasis(el, ctx, '*', 'inEm');
        case 'del': case 's': case 'strike':
          return wrapEmphasis(el, ctx, '~~', 'inDel');
        // ins/u/mark 在 Markdown 里没有对应语法，保留文本即可
        case 'ins': case 'u': case 'mark': case 'small': case 'abbr': case 'span':
        case 'font': case 'label': case 'time': case 'bdi': case 'bdo': case 'ruby':
          return renderInlineChildren(el, ctx);
        // 注音（日文振假名、中文拼音）在纯文本里会和正文交错，丢掉
        case 'rt': case 'rp': return '';
        case 'sup': case 'sub': {
          // Markdown 没有上下标语法。GFM 允许内联 HTML，原样保留信息量最大，
          // 代价是渲染成 HTML 时它是真的上下标标签（对我们的场景无害）。
          var innerSS = renderInlineChildren(el, ctx).trim();
          return innerSS ? '<' + tag + '>' + innerSS + '</' + tag + '>' : '';
        }
        case 'q': {
          var innerQ = renderInlineChildren(el, ctx).trim();
          return innerQ ? '\u201c' + innerQ + '\u201d' : '';
        }
        case 'math': return renderMath(el, ctx);
        default:
          return renderInlineChildren(el, ctx);
      }
    }

    // ---------------------------------------------------------------- 块级渲染

    /**
     * 混合内容的核心：逐个子节点走，行内片段先攒在缓冲区里，
     * 遇到块级子元素就把缓冲区作为一个段落冲出去。
     * 返回块数组（带 kind，供 joinItemBlocks 判断要不要空行）。
     */
    function renderChildren(el, ctx) {
      var blocks = [];
      var inline = '';
      var flush = function () {
        var t = tidyInline(inline);
        if (t) blocks.push(blk('p', t));
        inline = '';
      };

      var kids = el.childNodes;
      for (var i = 0; i < kids.length; i++) {
        if (ctx.stage >= 2) break;
        var node = kids[i];
        if (node.nodeType === 3) { inline += renderText(node, ctx, inline === ''); continue; }
        if (node.nodeType !== 1) continue;   // 注释、CDATA 等
        tick(ctx);
        var tag = tagOf(node);
        if (shouldDrop(node, tag, ctx)) continue;

        if (BLOCK_TAGS.has(tag)) {
          flush();
          var b = renderBlock(node, tag, ctx);
          if (b && b.t) blocks.push(b);
        } else {
          inline += renderInline(node, tag, ctx);
        }
      }
      flush();
      return blocks;
    }

    function renderHeading(el, tag, ctx) {
      var level = parseInt(tag.charAt(1), 10);
      if (!(level >= 1 && level <= 6)) level = 3;
      var text = tidyInline(renderInlineChildren(el, ctx)).replace(/\n+/g, ' ');
      if (!text) return blk('h', '');
      ctx.headings++;
      return blk('h', new Array(level + 1).join('#') + ' ' + text);
    }

    /**
     * 列表。支持嵌套、有序号（含 start / reversed）、任务列表。
     * 续行按标记宽度缩进，嵌套列表因此天然对齐。
     */
    function renderList(el, tag, ctx) {
      var ordered = tag === 'ol';
      var idx = ordered ? parseInt(attr(el, 'start'), 10) : 0;
      if (!isFinite(idx)) idx = 1;
      var reversed = ordered && el.hasAttribute('reversed');

      var lines = [];
      var trailing = [];   // 直接挂在 ul 下面的非 li 元素（畸形 HTML）
      var kids = el.children;
      for (var i = 0; i < kids.length; i++) {
        if (ctx.stage >= 2) break;
        var child = kids[i];
        var ctag = tagOf(child);
        if (shouldDrop(child, ctag, ctx)) continue;

        if (ctag !== 'li') {
          if (ctag === 'ul' || ctag === 'ol') {
            // 嵌套列表被放在 li 外面（常见的手写 HTML 错误）：缩进后并进来
            var nested = renderList(child, ctag, ctx).t;
            if (nested) lines.push(nested.split('\n').map(function (l) { return l ? '  ' + l : l; }).join('\n'));
          } else if (BLOCK_TAGS.has(ctag)) {
            var extra = renderBlock(child, ctag, ctx);
            if (extra && extra.t) trailing.push(extra.t);
          }
          continue;
        }

        // 任务列表：input 在 DROP_TAGS 里，得在丢掉之前把勾选状态读出来
        var box = child.querySelector('input[type="checkbox"]');
        var marker;
        if (box) {
          marker = '- [' + (box.checked ? 'x' : ' ') + '] ';
        } else {
          marker = ordered ? (idx + '. ') : '- ';
        }

        var body = joinItemBlocks(renderChildren(child, ctx)).trim();
        if (!body) { if (ordered && !box) idx += reversed ? -1 : 1; continue; }

        var pad = new Array(marker.length + 1).join(' ');
        var out = body.split('\n').map(function (line, n) {
          if (n === 0) return marker + line;
          return line ? pad + line : line;
        }).join('\n');
        lines.push(out);
        if (ordered && !box) idx += reversed ? -1 : 1;
      }

      var text = lines.join('\n');
      if (trailing.length) text += (text ? '\n\n' : '') + trailing.join('\n\n');
      return blk('list', text);
    }

    /** 语言标识：class="language-js" / "lang-js" / "highlight-source-js" / data-lang。 */
    function detectLang(pre) {
      var els = [pre];
      var codeEl = pre.querySelector('code');
      if (codeEl) els.push(codeEl);
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        var direct = attr(el, 'data-lang') || attr(el, 'data-language') ||
          attr(el, 'data-code-language') || attr(el, 'data-ke-language');
        if (direct) return normalizeLang(direct);
        var cls = classOf(el).split(/\s+/);
        for (var j = 0; j < cls.length; j++) {
          var m = /^(?:language|lang|highlight-source|brush:?|hljs-)[-:]?(.+)$/i.exec(cls[j]);
          if (m && m[1]) return normalizeLang(m[1]);
        }
      }
      return '';
    }

    function normalizeLang(s) {
      var t = str(s).toLowerCase().trim().replace(/[^a-z0-9+#._-]/g, '');
      if (!t || t === 'none' || t === 'text' || t === 'plain' || t === 'nohighlight') return '';
      return t.slice(0, 24);
    }

    /**
     * 取代码块文本。这里非用克隆不可：
     *   - 行号槽要摘掉（Prism / Pygments / GitHub 都会插一列数字）；
     *   - 有些编辑器视图用 <div class="line"> 分行，textContent 会把所有行连成一行，
     *     所以要在块级子元素后面补 \n；
     *   - <br> 分行的老页面也要还原成 \n。
     * 克隆的是 pre 这一小棵子树，代价可以接受。
     */
    function preText(pre) {
      var clone;
      try { clone = pre.cloneNode(true); } catch (e) { return str(pre.textContent); }

      var junk = clone.querySelectorAll(LINENO_SELECTOR);
      for (var i = 0; i < junk.length; i++) {
        if (junk[i].parentNode) junk[i].parentNode.removeChild(junk[i]);
      }
      var brs = clone.querySelectorAll('br');
      for (var j = 0; j < brs.length; j++) {
        if (brs[j].parentNode) brs[j].parentNode.replaceChild(clone.ownerDocument.createTextNode('\n'), brs[j]);
      }
      var lines = clone.querySelectorAll('div, p, tr, li');
      for (var k = 0; k < lines.length; k++) {
        var t = lines[k].textContent;
        if (t && !/\n$/.test(t)) lines[k].appendChild(clone.ownerDocument.createTextNode('\n'));
      }
      return str(clone.textContent);
    }

    /** 去掉整块共同的缩进（不少站点把代码整体缩进在 HTML 里）。 */
    function dedent(text) {
      var lines = text.split('\n');
      var min = Infinity;
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].trim()) continue;
        var m = /^[ \t]*/.exec(lines[i])[0].length;
        if (m < min) min = m;
      }
      if (!isFinite(min) || min === 0) return text;
      return lines.map(function (l) { return l.slice(min); }).join('\n');
    }

    function renderPre(el, ctx) {
      var lang = detectLang(el);
      var code = preText(el)
        .replace(/\u00a0/g, ' ')
        .replace(/\r\n?/g, '\n')
        .replace(/[ \t]+$/gm, '')
        .replace(/^\n+/, '')
        .replace(/\n+$/, '');
      code = dedent(code);
      if (!code.trim()) return blk('code', '');

      // 内容里出现 ``` 时用更长的围栏，否则代码块会被提前闭合
      var runs = code.match(/`{3,}/g) || [];
      var longest = 3;
      for (var i = 0; i < runs.length; i++) longest = Math.max(longest, runs[i].length + 1);
      var fence = new Array(longest + 1).join('`');
      return blk('code', fence + lang + '\n' + code + '\n' + fence);
    }

    function renderQuote(el, ctx) {
      var inner = joinBlocks(renderChildren(el, ctx)).trim();
      if (!inner) return blk('quote', '');
      // 嵌套 blockquote 里层已经带了 "> "，再加一层就是 "> > "，正好
      var out = inner.split('\n').map(function (l) { return l ? '> ' + l : '>'; }).join('\n');
      return blk('quote', out);
    }

    /** 单元格内容：块级结构摊平成一行，| 转义，避免把表格撑坏。 */
    function cellText(td, ctx) {
      var prev = ctx.inTable;
      ctx.inTable = true;
      var s = joinBlocks(renderChildren(td, ctx));
      ctx.inTable = prev;
      return s.replace(/\s*\n+\s*/g, ' ').replace(/\s{2,}/g, ' ').trim();
    }

    /**
     * 表格 → GFM。
     * colspan/rowspan、嵌套表格都没法用 GFM 表达，硬转会产出错行的坏表格，
     * 所以这些情况降级成「每行一条、单元格用 | 分隔」的列表，信息不丢、结构不烂。
     */
    function renderTable(el, ctx) {
      var allRows = el.querySelectorAll('tr');
      var rows = [];
      var degrade = false;

      for (var i = 0; i < allRows.length; i++) {
        var tr = allRows[i];
        // 嵌套表格的 tr 归它自己的 table 管
        if (tr.closest && tr.closest('table') !== el) continue;
        if (shouldDrop(tr, 'tr', ctx)) continue;

        var cells = [];
        var isHead = true;
        var kids = tr.children;
        for (var j = 0; j < kids.length; j++) {
          var td = kids[j];
          var ctag = tagOf(td);
          if (ctag !== 'td' && ctag !== 'th') continue;
          if (ctag !== 'th') isHead = false;
          var cs = parseInt(attr(td, 'colspan'), 10);
          var rs = parseInt(attr(td, 'rowspan'), 10);
          if ((isFinite(cs) && cs > 1) || (isFinite(rs) && rs > 1)) degrade = true;
          if (td.querySelector('table')) degrade = true;
          cells.push(cellText(td, ctx));
        }
        if (!cells.length) continue;
        rows.push({ cells: cells, head: isHead });
      }
      if (!rows.length) return blk('table', '');

      var caption = '';
      var cap = el.querySelector('caption');
      if (cap && cap.closest('table') === el) caption = tidyInline(renderInlineChildren(cap, ctx));

      var width = 0;
      for (var r = 0; r < rows.length; r++) width = Math.max(width, rows[r].cells.length);

      if (degrade) {
        var lines = rows.map(function (row) {
          return '- ' + row.cells.join(' | ');
        });
        var head = caption ? '**' + caption + '**\n' : '';
        // 合并单元格无法用 GFM 表达，这里如实降级为按行拼接
        return blk('table', head + lines.join('\n'));
      }

      var pad = function (cells) {
        var out = cells.slice();
        while (out.length < width) out.push('');
        return '| ' + out.map(function (c) { return c || ' '; }).join(' | ') + ' |';
      };

      var body = [];
      var headerRow = rows[0];
      // 没有 th 就把第一行当表头：GFM 表格必须有表头行，
      // 这样至少表格是完整可读的（代价是首行数据被标成了表头）
      body.push(pad(headerRow.cells));
      body.push('| ' + new Array(width + 1).join('--- |').replace(/\|$/, '|').split('|').slice(0, -1).join('| ').trim());
      // 上面那行太绕，直接重算一遍更稳妥
      body[1] = '|' + new Array(width + 1).join(' --- |');
      for (var q = 1; q < rows.length; q++) body.push(pad(rows[q].cells));

      var text = body.join('\n');
      if (caption) text = '**' + caption + '**\n\n' + text;
      return blk('table', text);
    }

    /** 定义列表：dt 加粗，dd 用 ": " 前缀（pandoc/markdown-it 的 deflist 约定）。 */
    function renderDl(el, ctx) {
      var out = [];
      var kids = el.children;
      for (var i = 0; i < kids.length; i++) {
        var child = kids[i];
        var tag = tagOf(child);
        if (shouldDrop(child, tag, ctx)) continue;
        if (tag === 'dt') {
          var term = tidyInline(renderInlineChildren(child, ctx)).replace(/\n+/g, ' ');
          if (term) out.push((out.length ? '\n' : '') + '**' + term + '**');
        } else if (tag === 'dd') {
          var def = joinBlocks(renderChildren(child, ctx)).trim();
          if (def) {
            out.push(def.split('\n').map(function (l, n) {
              return n === 0 ? ': ' + l : (l ? '  ' + l : l);
            }).join('\n'));
          }
        }
      }
      return blk('dl', out.join('\n'));
    }

    /** figure：图片 + 说明。图片 alt 为空时借用 figcaption 当 alt。 */
    function renderFigure(el, ctx) {
      var cap = null;
      var kids = el.children;
      for (var i = 0; i < kids.length; i++) {
        if (tagOf(kids[i]) === 'figcaption') { cap = kids[i]; break; }
      }
      var capText = cap ? tidyInline(renderInlineChildren(cap, ctx)).replace(/\n+/g, ' ') : '';

      if (cap) ctx.skip.add(cap);
      var inner = joinBlocks(renderChildren(el, ctx)).trim();
      if (cap) ctx.skip.delete(cap);

      // ![](url) + 说明 → 把说明填进 alt，同时另起一行保留原说明
      if (capText) {
        inner = inner.replace(/^!\[\]\(/, '![' + capText.replace(/([[\]])/g, '\\$1') + '](');
      }
      var parts = [];
      if (inner) parts.push(inner);
      if (capText) parts.push('*' + capText + '*');
      return blk('figure', parts.join('\n\n'));
    }

    function renderDetails(el, ctx) {
      var sum = null;
      var kids = el.children;
      for (var i = 0; i < kids.length; i++) {
        if (tagOf(kids[i]) === 'summary') { sum = kids[i]; break; }
      }
      var head = sum ? tidyInline(renderInlineChildren(sum, ctx)).replace(/\n+/g, ' ') : '';
      if (sum) ctx.skip.add(sum);
      var body = joinBlocks(renderChildren(el, ctx)).trim();
      if (sum) ctx.skip.delete(sum);
      var parts = [];
      if (head) parts.push('**' + head + '**');
      if (body) parts.push(body);
      return blk('details', parts.join('\n\n'));
    }

    function renderBlock(el, tag, ctx) {
      switch (tag) {
        case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6':
          return renderHeading(el, tag, ctx);
        case 'hr':
          return blk('hr', '---');
        case 'ul': case 'ol': case 'menu':
          return renderList(el, tag === 'ol' ? 'ol' : 'ul', ctx);
        case 'pre':
          return renderPre(el, ctx);
        case 'blockquote':
          return renderQuote(el, ctx);
        case 'table':
          return renderTable(el, ctx);
        case 'dl':
          return renderDl(el, ctx);
        case 'figure':
          return renderFigure(el, ctx);
        case 'details':
          return renderDetails(el, ctx);
        case 'p': case 'summary': case 'figcaption': case 'caption': case 'legend':
          return blk('p', tidyInline(renderInlineChildren(el, ctx)));
        // 孤立出现的表格片段（正常路径下由 renderTable 接管，这里兜住畸形 HTML）
        case 'tr': case 'td': case 'th': case 'thead': case 'tbody': case 'tfoot':
          return blk('p', joinBlocks(renderChildren(el, ctx)));
        default:
          // div / section / article / li / dd 等纯容器：递归即可
          return blk('group', joinBlocks(renderChildren(el, ctx)));
      }
    }

    // ---------------------------------------------------------------- 后处理

    /**
     * 连续、指向同一 URL 的重复链接收敛。
     * 典型来源：卡片列表里 <a href=X><img></a><a href=X>标题</a>，
     * 转出来就是紧挨着的两个同址链接。保留信息量大的那个。
     */
    function dedupeLinks(md) {
      var re = /(!?\[[^\]\n]*\]\((\S+?)\))([ \t]*)(!?\[[^\]\n]*\]\(\2\))/g;
      for (var pass = 0; pass < 3; pass++) {
        var before = md;
        md = md.replace(re, function (all, a, url, ws, b) {
          // 图片链接信息量低于文字链接；同类型则留长的
          var aIsImg = a.charAt(0) === '!';
          var bIsImg = b.charAt(0) === '!';
          if (aIsImg !== bIsImg) return aIsImg ? b : a;
          return a.length >= b.length ? a : b;
        });
        if (md === before) break;
      }
      return md;
    }

    /**
     * 空白归一。必须绕开代码块：代码里的空行和缩进是内容的一部分。
     */
    function postProcess(md) {
      var text = str(md)
        .replace(/\u00a0/g, ' ')
        .replace(/[\u200b-\u200d\ufeff]/g, '');

      var lines = text.split('\n');
      var out = [];
      var inFence = false;
      var fenceMark = '';
      var blanks = 0;

      for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        var fm = /^(`{3,}|~{3,})/.exec(line.trim());
        if (fm) {
          if (!inFence) { inFence = true; fenceMark = fm[1].charAt(0); }
          else if (fm[1].charAt(0) === fenceMark) { inFence = false; fenceMark = ''; }
          out.push(line.replace(/[ \t]+$/, ''));
          blanks = 0;
          continue;
        }
        if (inFence) { out.push(line); continue; }

        line = line.replace(/[ \t]+$/, '');
        if (!line.trim()) {
          blanks++;
          if (blanks > 1) continue;      // 连续空行压成一个
          out.push('');
        } else {
          blanks = 0;
          out.push(line);
        }
      }

      // 围栏没闭合（页面被截断或 HTML 畸形）时补一个，否则整段后文都被吞进代码块
      if (inFence) out.push(fenceMark === '~' ? '~~~' : '```');

      var joined = out.join('\n');
      joined = dedupeLinks(joined);
      return joined.trim();
    }

    /**
     * 从尾部截断，且不把一行 Markdown 语法切碎。
     * 顺序：退到段落边界 → 退到行边界 → 丢掉尾行里没配平的 [ ( → 补上未闭合的围栏。
     */
    function truncate(md, maxChars) {
      if (md.length <= maxChars) return { text: md, truncated: false };

      var cut = md.slice(0, maxChars);
      var para = cut.lastIndexOf('\n\n');
      var line = cut.lastIndexOf('\n');
      if (para >= maxChars - 4000) cut = cut.slice(0, para);
      else if (line >= maxChars - 500) cut = cut.slice(0, line);

      // 尾行里可能是半截的 ![alt]( 或 [text](，直接丢掉这一行
      var nl = cut.lastIndexOf('\n');
      var tail = nl < 0 ? cut : cut.slice(nl + 1);
      var opens = (tail.match(/\[/g) || []).length + (tail.match(/\(/g) || []).length;
      var closes = (tail.match(/\]/g) || []).length + (tail.match(/\)/g) || []).length;
      if (opens !== closes) cut = nl < 0 ? '' : cut.slice(0, nl);

      // 围栏配平
      var fences = (cut.match(/^```/gm) || []).length;
      if (fences % 2 === 1) cut += '\n```';

      return { text: cut.replace(/\s+$/, '') + '\n\n…（内容已截断）', truncated: true };
    }

    // ---------------------------------------------------------------- 兜底

    /** 转换过程整个炸了时的最后一道保险：至少把文字捞回来。 */
    function fallbackText() {
      try {
        var el = document.body || document.documentElement;
        var t = el ? (el.innerText || el.textContent || '') : '';
        return str(t).replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
      } catch (e) {
        return '';
      }
    }

    // ---------------------------------------------------------------- 入口

    /**
     * @param {{maxChars?:number, budgetMs?:number, root?:Element}} [options]
     *        root 是测试和调试用的口子：把某个元素当成「页面」来抽取。
     *        正常调用不要传，由 pickRoot 自己找。
     */
    function newCtx(opts, keepNav) {
      return {
        keepNav: keepNav,
        t0: now(),
        budgetMs: num(opts.budgetMs, DEFAULTS.budgetMs),
        stage: 0,
        degraded: '',
        nodes: 0,
        styles: new WeakMap(),
        skip: new Set(),
        root: null,
        dropHeader: true,
        noiseGuard: 1000,
        pageUrl: pageUrlNoHash(),
        images: 0,
        links: 0,
        headings: 0,
        inLink: false,
        inTable: false,
        inCode: false,
        inStrong: false,
        inEm: false,
        inDel: false
      };
    }

    // 页面上看得见的文字量（innerText 只算渲染出来的；拿不到就用 textContent）
    function visibleLen(scope) {
      try { return str(scope.innerText).replace(/\s+/g, ' ').trim().length; } catch (e) { return textLen(scope); }
    }

    function extract(options) {
      var opts = options || {};
      var maxChars = num(opts.maxChars, DEFAULTS.maxChars);
      var ctx = newCtx(opts, false);

      var markdown = '';
      var how = 'body';
      var error = '';

      try {
        var scope = opts.root || document.body || document.documentElement;
        var picked = pickRoot(scope);
        ctx.root = picked.el;
        how = picked.how;
        // 没能定位到正文（退回 body）时，页头页脚是纯噪音，丢掉；
        // 定位到正文容器时，容器内的 <header> 往往是文章标题，要留。
        ctx.dropHeader = (how === 'body');
        // 广告特征词的「误伤保护」阈值随页面体量走
        ctx.noiseGuard = Math.max(300, Math.min(4000, textLen(ctx.root) * 0.2));

        markdown = joinBlocks(renderChildren(ctx.root, ctx));
      } catch (e) {
        error = str(e && e.message ? e.message : e);
        markdown = fallbackText();
        how = 'fallback-text';
      }

      markdown = postProcess(markdown);

      // 导航页第二遍：第一遍剩下的不到 600 字符，而页面上看得见的文字多得多
      // （门户页、导航站：内容本身就是导航，第一遍按「导航不是正文」全丢了），
      // 就以整页为根、保留导航再抽一遍，结果更长才采用。正常文章页不会触发。
      if (how !== 'fallback-text' && markdown.length < 600) {
        try {
          var page = opts.root || document.body || document.documentElement;
          if (visibleLen(page) > markdown.length * 3 + 300) {
            var navCtx = newCtx(opts, true);
            navCtx.root = page;
            navCtx.dropHeader = true;
            navCtx.noiseGuard = Math.max(300, Math.min(4000, textLen(page) * 0.2));
            var withNav = postProcess(joinBlocks(renderChildren(page, navCtx)));
            if (withNav.length > markdown.length) {
              markdown = withNav;
              ctx = navCtx;
              how = how + '+nav';
            }
          }
        } catch (e) { /* keep the first pass */ }
      }

      // 正文一个字都没捞到（全是 canvas / 图片 / 极端 SPA）→ 退回纯文本
      if (!markdown && how !== 'fallback-text') {
        markdown = postProcess(fallbackText());
        how = 'fallback-text';
      }

      var cut = truncate(markdown, maxChars);
      markdown = cut.text;

      var title = '';
      try { title = str(document.title).trim(); } catch (e) { title = ''; }

      return {
        url: ctx.pageUrl ? (function () { try { return document.baseURI; } catch (e) { return ''; } })() : '',
        title: title,
        markdown: markdown,
        truncated: cut.truncated || ctx.stage >= 2,
        stats: {
          chars: markdown.length,
          images: ctx.images,
          links: ctx.links,
          headings: ctx.headings,
          // 契约之外的诊断字段，只增不改，消费方可以完全忽略
          root: how,
          nodes: ctx.nodes,
          elapsedMs: Math.round(now() - ctx.t0),
          degraded: ctx.degraded || '',
          error: error
        }
      };
    }

    window.__webchatMarkdown = {
      version: VERSION,
      extract: extract,
      // 自测页要用的内部函数。生产代码不要依赖。
      _debug: {
        pickRoot: pickRoot,
        postProcess: postProcess,
        truncate: truncate,
        absUrl: absUrl,
        pickImageSrc: pickImageSrc,
        pickFromSrcset: pickFromSrcset
      }
    };
  })();
}
