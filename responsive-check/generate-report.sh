#!/bin/bash
# ============================================================
# 响应式检查报告生成脚本
# 用法: ./generate-report.sh <截图目录> [页面URL]
# 示例: ./generate-report.sh ./51cg1.com/home https://51cg1.com/
#
# 在截图目录下放置 annotations.conf 可添加:
#   - 设备评价 (eval)
#   - 首屏截图标注框 (anno)
#   - 滚动截图标注框 (scroll_anno)
#   - 问题与优化建议 (issue)
# ============================================================

set -euo pipefail

# ---------- 参数解析 ----------
SCREENSHOT_DIR="${1:-.}"
PAGE_URL="${2:-未指定}"
REPORT_DATE=$(date '+%Y-%m-%d %H:%M:%S')
OUTPUT="$SCREENSHOT_DIR/index.html"
ANNOTATIONS_FILE="$SCREENSHOT_DIR/annotations.conf"

if [ ! -d "$SCREENSHOT_DIR" ]; then
  echo "错误: 截图目录不存在: $SCREENSHOT_DIR"
  exit 1
fi

# ---------- 工具函数 ----------
b64_img() {
  local file="$1"
  if [ -f "$file" ]; then
    # macOS 用 base64 -i, Linux 用 base64 -w0
    local b64data
    if [[ "$(uname)" == "Darwin" ]]; then
      b64data=$(base64 -i "$file" | tr -d '\n')
    else
      b64data=$(base64 -w0 "$file")
    fi
    echo -n "data:image/png;base64,${b64data}"
  else
    echo -n ""
  fi
}

# ---------- 读取标注配置 ----------
# 存储到临时文件，按类型分类
EVAL_TEMP=$(mktemp)
ANNO_TEMP=$(mktemp)
SCROLL_ANNO_TEMP=$(mktemp)
ISSUE_TEMP=$(mktemp)
trap "rm -f $EVAL_TEMP $ANNO_TEMP $SCROLL_ANNO_TEMP $ISSUE_TEMP" EXIT

if [ -f "$ANNOTATIONS_FILE" ]; then
  echo "读取标注配置: $ANNOTATIONS_FILE" >&2
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    case "$line" in
      eval\|*)        echo "$line" >> "$EVAL_TEMP" ;;
      anno\|*)        echo "$line" >> "$ANNO_TEMP" ;;
      scroll_anno\|*) echo "$line" >> "$SCROLL_ANNO_TEMP" ;;
      issue\|*)       echo "$line" >> "$ISSUE_TEMP" ;;
    esac
  done < "$ANNOTATIONS_FILE"
fi

# 查询设备评价: get_eval <prefix> → "ok|描述" 或空
get_eval() {
  local prefix="$1"
  grep "^eval|${prefix}|" "$EVAL_TEMP" 2>/dev/null | head -1 | cut -d'|' -f3-4 || true
}

# 查询首屏标注: get_annotations <prefix> → 多行 "top|left|width|height|label"
get_annotations() {
  local prefix="$1"
  grep "^anno|${prefix}|" "$ANNO_TEMP" 2>/dev/null | cut -d'|' -f3- || true
}

# 查询滚动标注: get_scroll_annotations <prefix> <scroll_idx> → 多行
get_scroll_annotations() {
  local prefix="$1" idx="$2"
  grep "^scroll_anno|${prefix}|${idx}|" "$SCROLL_ANNO_TEMP" 2>/dev/null | cut -d'|' -f4- || true
}

# 生成标注 HTML
render_annotations() {
  local annos="$1"
  [ -z "$annos" ] && return
  while IFS='|' read -r top left width height label; do
    [ -z "$top" ] && continue
    cat << ANNO_HTML
<div class="annotation" style="top:${top}%;left:${left}%;width:${width}%;height:${height}%"><span class="annotation-label">${label}</span></div>
ANNO_HTML
  done <<< "$annos"
}

# ---------- 设备检测 ----------
detect_devices() {
  local dir="$1"
  local -a prefixes=()
  for f in "$dir"/*-scroll0.png "$dir"/*-scroll0.jpg; do
    [ -f "$f" ] || continue
    local basename=$(basename "$f")
    local prefix="${basename%-scroll0.*}"
    prefixes+=("$prefix")
  done
  if [ ${#prefixes[@]} -eq 0 ]; then
    for f in "$dir"/*.png "$dir"/*.jpg; do
      [ -f "$f" ] || continue
      local basename=$(basename "$f")
      [[ "$basename" == *-scroll* ]] && continue
      [[ "$basename" == "index."* ]] && continue
      local prefix="${basename%.*}"
      prefixes+=("$prefix")
    done
  fi
  echo "${prefixes[@]}"
}

get_device_screenshots() {
  local dir="$1" prefix="$2"
  local -a files=()
  for f in "$dir/${prefix}-scroll0."*; do
    [ -f "$f" ] && files+=("$f")
  done
  for i in $(seq 1 20); do
    for f in "$dir/${prefix}-scroll${i}."*; do
      [ -f "$f" ] && files+=("$f")
    done
  done
  echo "${files[@]}"
}

parse_device_info() {
  local prefix="$1"
  local name="" width="" height=""
  case "$prefix" in
    *iphone-se*|*iPhoneSE*|*iphonese*)   name="iPhone SE"; width="375"; height="667" ;;
    *iphone14*|*iPhone14*|*iphone-14*)    name="iPhone 14"; width="390"; height="844" ;;
    *iphone15*|*iPhone15*|*iphone-15*)    name="iPhone 15"; width="393"; height="852" ;;
    *ipad-mini*|*iPadMini*|*ipadmini*)    name="iPad Mini"; width="768"; height="1024" ;;
    *ipad-pro*|*iPadPro*|*ipadpro*)       name="iPad Pro"; width="1024"; height="1366" ;;
    *laptop*|*Laptop*|*notebook*)          name="笔记本"; width="1366"; height="768" ;;
    *desktop*|*Desktop*|*desktop*)         name="桌面"; width="1920"; height="1080" ;;
    *)
      if [[ "$prefix" =~ ([0-9]+)x([0-9]+) ]]; then
        width="${BASH_REMATCH[1]}"; height="${BASH_REMATCH[2]}"; name="设备 ${width}×${height}"
      else
        name="$prefix"; width="?"; height="?"
      fi ;;
  esac
  echo "$name|$width|$height"
}

# ---------- 生成 HTML ----------
generate_html() {
  local dir="$1"
  local prefixes_str
  prefixes_str=$(detect_devices "$dir")
  local -a prefixes=($prefixes_str)

  if [ ${#prefixes[@]} -eq 0 ]; then
    echo "错误: 在 $dir 中未找到截图文件" >&2
    exit 1
  fi

  echo "找到 ${#prefixes[@]} 个设备的截图，开始生成报告..." >&2

  # ===== HTML 头部 =====
  cat << 'HTML_HEAD'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>响应式检查报告</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",sans-serif;background:#1a1a2e;color:#e0e0e0;line-height:1.6}
.container{max-width:1400px;margin:0 auto;padding:20px}
header{text-align:center;padding:40px 20px;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);border-radius:12px;margin-bottom:30px}
header h1{font-size:28px;color:#fff;margin-bottom:10px}
header .meta{color:rgba(255,255,255,.8);font-size:14px}
header .meta span{margin:0 8px}

/* 汇总表格 */
.summary-table{width:100%;border-collapse:collapse;margin:30px 0;background:#16213e;border-radius:8px;overflow:hidden}
.summary-table th{background:#0f3460;padding:12px 16px;text-align:left;font-weight:600;color:#e94560}
.summary-table td{padding:10px 16px;border-bottom:1px solid #1a1a2e}
.summary-table tr:last-child td{border-bottom:none}
.summary-table tr:hover td{background:#1a2744}

/* 徽章 */
.badge{display:inline-block;padding:2px 10px;border-radius:12px;font-size:12px;font-weight:600}
.badge-ok{background:#00b894;color:#fff}
.badge-warn{background:#fdcb6e;color:#2d3436}
.badge-error{background:#e17055;color:#fff}
.badge-info{background:#74b9ff;color:#2d3436}

/* 标题 */
.section-title{font-size:22px;margin:30px 0 15px;padding-bottom:8px;border-bottom:2px solid #e94560;display:inline-block}

/* 卡片网格 */
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:24px;margin:20px 0}
.card{background:#16213e;border-radius:12px;overflow:hidden;transition:transform .2s,box-shadow .2s}
.card:hover{transform:translateY(-4px);box-shadow:0 8px 24px rgba(0,0,0,.3)}
.card-header{padding:12px 16px;background:#0f3460;display:flex;justify-content:space-between;align-items:center}
.card-header h3{font-size:14px;color:#e94560}
.card-body{position:relative;padding:8px;cursor:pointer}
.card-body img{width:100%;height:auto;border-radius:4px;display:block}
.card-footer{padding:10px 16px;font-size:13px;color:#aaa}

/* 问题标注框 */
.annotation{position:absolute;border:2.5px solid #ff4444;background:rgba(255,68,68,.08);border-radius:4px;pointer-events:none;animation:pulse 2s infinite}
.annotation-label{position:absolute;top:-22px;left:0;background:#ff4444;color:#fff;font-size:11px;padding:1px 6px;border-radius:3px;white-space:nowrap}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.6}}

/* 问题列表 */
.issues{background:#16213e;border-radius:12px;padding:20px;margin:20px 0}
.issue-item{padding:12px 16px;margin:8px 0;background:#1a1a2e;border-left:4px solid #e17055;border-radius:0 8px 8px 0}
.issue-item h4{color:#e17055;margin-bottom:4px;font-size:15px}
.issue-item p{font-size:14px;color:#bbb;margin:4px 0}
.issue-item strong{color:#ddd}

/* 滚动截图折叠 */
.scroll-group{margin:16px 0}
.scroll-toggle{background:#0f3460;color:#e94560;border:none;padding:10px 20px;border-radius:8px;cursor:pointer;font-size:14px;font-weight:600;width:100%;text-align:left;display:flex;justify-content:space-between;align-items:center}
.scroll-toggle:hover{background:#153575}
.scroll-toggle .arrow{transition:transform .3s}
.scroll-toggle.open .arrow{transform:rotate(180deg)}
.scroll-content{display:none;padding:16px 0}
.scroll-content.open{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:16px}

/* Lightbox */
.lightbox{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.92);z-index:1000;justify-content:center;align-items:center;flex-direction:column;opacity:0;transition:opacity .3s}
.lightbox.active{display:flex;opacity:1}
.lightbox img{max-width:95vw;max-height:85vh;object-fit:contain;transition:transform .2s ease}
.lightbox-title{color:#fff;margin-top:12px;font-size:14px;text-align:center}
.lightbox-close{position:absolute;top:20px;right:30px;color:#fff;font-size:36px;cursor:pointer;line-height:1;opacity:.8;transition:opacity .2s}
.lightbox-close:hover{opacity:1}
.lightbox-hint{position:absolute;bottom:20px;color:rgba(255,255,255,.4);font-size:12px}

/* 响应式 */
@media(max-width:768px){
  .cards{grid-template-columns:1fr}
  .scroll-content.open{grid-template-columns:1fr}
  header h1{font-size:22px}
  .container{padding:12px}
}
</style>
</head>
<body>
<div class="container">
HTML_HEAD

  # ===== Header =====
  cat << HEADER
<header>
<h1>响应式布局检查报告</h1>
<div class="meta">
<span>目标页面：${PAGE_URL}</span>
<span>|</span>
<span>检查时间：${REPORT_DATE}</span>
<span>|</span>
<span>设备数：${#prefixes[@]}</span>
</div>
</header>
HEADER

  # ===== 汇总表格 =====
  cat << 'TABLE_HEAD'
<h2 class="section-title">检查结果汇总</h2>
<table class="summary-table">
<tr><th>设备</th><th>分辨率</th><th>截图数</th><th>布局模式</th><th>评价</th><th>问题</th></tr>
TABLE_HEAD

  for prefix in "${prefixes[@]}"; do
    local info
    info=$(parse_device_info "$prefix")
    local dev_name dev_w dev_h
    IFS='|' read -r dev_name dev_w dev_h <<< "$info"

    local screenshots_str
    screenshots_str=$(get_device_screenshots "$dir" "$prefix")
    local -a screenshots=($screenshots_str)
    local count=${#screenshots[@]}

    local layout=""
    if [ "$dev_w" != "?" ]; then
      if [ "$dev_w" -le 480 ]; then layout="移动端单列"
      elif [ "$dev_w" -le 820 ]; then layout="平板端"
      else layout="桌面端"
      fi
    else layout="未知"
    fi

    # 读取评价
    local eval_str badge_class badge_text problem_text
    eval_str=$(get_eval "$prefix")
    if [ -n "$eval_str" ]; then
      badge_class=$(echo "$eval_str" | cut -d'|' -f1)
      problem_text=$(echo "$eval_str" | cut -d'|' -f2)
      case "$badge_class" in
        ok)    badge_text="布局正常" ;;
        warn)  badge_text="有问题" ;;
        error) badge_text="严重问题" ;;
        *)     badge_text="已检查"; badge_class="info" ;;
      esac
    else
      badge_class="info"; badge_text="已检查"; problem_text="-"
    fi

    cat << ROW
<tr>
<td>${dev_name}</td>
<td>${dev_w}×${dev_h}</td>
<td>${count} 张</td>
<td>${layout}</td>
<td><span class="badge badge-${badge_class}">${badge_text}</span></td>
<td>${problem_text}</td>
</tr>
ROW
  done

  echo '</table>'

  # ===== 首屏截图卡片（带标注框） =====
  cat << 'SECTION'
<h2 class="section-title">各分辨率首屏截图</h2>
<div class="cards">
SECTION

  for prefix in "${prefixes[@]}"; do
    local info
    info=$(parse_device_info "$prefix")
    local dev_name dev_w dev_h
    IFS='|' read -r dev_name dev_w dev_h <<< "$info"

    local hero_file=""
    for ext in png jpg jpeg; do
      [ -f "$dir/${prefix}-scroll0.${ext}" ] && hero_file="$dir/${prefix}-scroll0.${ext}" && break
      [ -f "$dir/${prefix}.${ext}" ] && hero_file="$dir/${prefix}.${ext}" && break
    done
    [ -z "$hero_file" ] && continue

    echo "  处理: $dev_name (${dev_w}×${dev_h})..." >&2

    local b64src
    b64src=$(b64_img "$hero_file")

    # 评价徽章
    local eval_str badge_class badge_text
    eval_str=$(get_eval "$prefix")
    if [ -n "$eval_str" ]; then
      badge_class=$(echo "$eval_str" | cut -d'|' -f1)
      case "$badge_class" in
        ok)    badge_text="布局正常" ;;
        warn)  badge_text="有问题" ;;
        error) badge_text="严重问题" ;;
        *)     badge_text="首屏"; badge_class="info" ;;
      esac
    else
      badge_class="info"; badge_text="首屏"
    fi

    # 标注框 HTML
    local annos_str annotation_html footer_text
    annos_str=$(get_annotations "$prefix")
    annotation_html=$(render_annotations "$annos_str")

    if [ -n "$annos_str" ] && [ -n "$annotation_html" ]; then
      footer_text="首屏截图 — 已标注问题区域"
    else
      if [ "$badge_class" = "ok" ]; then
        footer_text='首屏截图 — <span class="badge badge-ok">布局正常</span>'
      else
        footer_text="首屏视口截图"
      fi
    fi

    cat << CARD
<div class="card">
<div class="card-header">
<h3>${dev_name} (${dev_w}×${dev_h})</h3>
<span class="badge badge-${badge_class}">${badge_text}</span>
</div>
<div class="card-body" onclick="openLightbox(this)">
<img src="${b64src}" alt="${dev_name} 首屏" data-title="${dev_name} (${dev_w}×${dev_h}) - 首屏">
${annotation_html}
</div>
<div class="card-footer">${footer_text}</div>
</div>
CARD
  done

  echo '</div>'

  # ===== 发现的问题与优化建议 =====
  if [ -s "$ISSUE_TEMP" ]; then
    cat << 'ISSUE_HEAD'
<h2 class="section-title">发现的问题与优化建议</h2>
<div class="issues">
ISSUE_HEAD

    while IFS='|' read -r _type idx title desc suggestion; do
      [ -z "$idx" ] && continue
      cat << ISSUE_ITEM
<div class="issue-item">
<h4>${idx}. ${title}</h4>
<p>${desc}</p>
<p><strong>建议：</strong>${suggestion}</p>
</div>
ISSUE_ITEM
    done < "$ISSUE_TEMP"

    echo '</div>'
  fi

  # ===== 滚动截图（按设备分组折叠，带标注框） =====
  cat << 'SCROLL_SECTION'
<h2 class="section-title">滚动截图详情</h2>
SCROLL_SECTION

  local group_idx=0
  for prefix in "${prefixes[@]}"; do
    local info
    info=$(parse_device_info "$prefix")
    local dev_name dev_w dev_h
    IFS='|' read -r dev_name dev_w dev_h <<< "$info"

    local -a scroll_files=()
    for i in $(seq 1 20); do
      for ext in png jpg jpeg; do
        [ -f "$dir/${prefix}-scroll${i}.${ext}" ] && scroll_files+=("$dir/${prefix}-scroll${i}.${ext}") && break
      done
    done
    [ ${#scroll_files[@]} -eq 0 ] && continue

    cat << TOGGLE
<div class="scroll-group">
<button class="scroll-toggle" onclick="toggleScroll(this, 'scroll-${group_idx}')">
<span>${dev_name} (${dev_w}×${dev_h}) — ${#scroll_files[@]} 张滚动截图</span>
<span class="arrow">▼</span>
</button>
<div class="scroll-content" id="scroll-${group_idx}">
TOGGLE

    local scroll_idx=1
    for sf in "${scroll_files[@]}"; do
      local sb64
      sb64=$(b64_img "$sf")

      # 查询该滚动截图是否有标注
      local scroll_annos scroll_anno_html
      scroll_annos=$(get_scroll_annotations "$prefix" "$scroll_idx")
      scroll_anno_html=$(render_annotations "$scroll_annos")

      local scroll_badge=""
      if [ -n "$scroll_annos" ] && [ -n "$scroll_anno_html" ]; then
        scroll_badge='<span class="badge badge-warn">有问题</span>'
      fi

      cat << SCROLL_CARD
<div class="card">
<div class="card-header">
<h3>${dev_name} — 第 ${scroll_idx} 屏</h3>
${scroll_badge}
</div>
<div class="card-body" onclick="openLightbox(this)">
<img src="${sb64}" alt="${dev_name} 滚动${scroll_idx}" data-title="${dev_name} (${dev_w}×${dev_h}) - 第 ${scroll_idx} 屏">
${scroll_anno_html}
</div>
</div>
SCROLL_CARD
      scroll_idx=$((scroll_idx + 1))
    done

    echo '</div></div>'
    group_idx=$((group_idx + 1))
  done

  # ===== Lightbox + JS =====
  cat << 'FOOTER'
</div>

<!-- Lightbox -->
<div class="lightbox" id="lightbox">
<span class="lightbox-close" onclick="closeLightbox()">&times;</span>
<img id="lightbox-img" src="" alt="">
<div class="lightbox-title" id="lightbox-title"></div>
<div class="lightbox-hint">滚轮缩放 · 双击复位 · 点击空白/ESC 关闭</div>
</div>

<script>
let currentScale = 1;

function openLightbox(el) {
  const img = el.querySelector('img');
  if (!img) return;
  const lb = document.getElementById('lightbox');
  const lbImg = document.getElementById('lightbox-img');
  const lbTitle = document.getElementById('lightbox-title');
  lbImg.src = img.src;
  lbTitle.textContent = img.dataset.title || '';
  currentScale = 1;
  lbImg.style.transform = 'scale(1)';
  lb.style.display = 'flex';
  requestAnimationFrame(() => lb.classList.add('active'));
}

function closeLightbox() {
  const lb = document.getElementById('lightbox');
  lb.classList.remove('active');
  setTimeout(() => { lb.style.display = 'none'; }, 300);
}

document.getElementById('lightbox').addEventListener('click', function(e) {
  if (e.target === this) closeLightbox();
});

document.addEventListener('keydown', function(e) {
  if (e.key === 'Escape') closeLightbox();
});

document.getElementById('lightbox-img').addEventListener('wheel', function(e) {
  e.preventDefault();
  currentScale += e.deltaY < 0 ? 0.1 : -0.1;
  currentScale = Math.max(0.5, Math.min(5, currentScale));
  this.style.transform = 'scale(' + currentScale + ')';
}, { passive: false });

document.getElementById('lightbox-img').addEventListener('dblclick', function() {
  currentScale = 1;
  this.style.transform = 'scale(1)';
});

function toggleScroll(btn, id) {
  const el = document.getElementById(id);
  btn.classList.toggle('open');
  el.classList.toggle('open');
}
</script>
</body>
</html>
FOOTER
}

# ---------- 执行 ----------
echo "================================================"
echo "  响应式检查报告生成器"
echo "================================================"
echo "截图目录: $SCREENSHOT_DIR"
echo "页面地址: $PAGE_URL"
if [ -f "$ANNOTATIONS_FILE" ]; then
  echo "标注配置: $ANNOTATIONS_FILE"
else
  echo "标注配置: (未找到 annotations.conf，将不显示标注和问题)"
fi
echo ""

generate_html "$SCREENSHOT_DIR" > "$OUTPUT"

FILE_SIZE=$(wc -c < "$OUTPUT" | tr -d ' ')
FILE_SIZE_KB=$((FILE_SIZE / 1024))

echo "" >&2
echo "================================================" >&2
echo "  报告已生成!" >&2
echo "  文件: $OUTPUT" >&2
echo "  大小: ${FILE_SIZE_KB} KB" >&2
echo "================================================" >&2

# 自动打开
if command -v open &>/dev/null; then
  open "$OUTPUT"
  echo "  已在浏览器中打开" >&2
elif command -v xdg-open &>/dev/null; then
  xdg-open "$OUTPUT"
  echo "  已在浏览器中打开" >&2
fi
