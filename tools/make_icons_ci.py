# CI 用：在云端编译前生成 App 图标（默认款 A「流光三线」，纯黑底 + 白色圆角三线）
# 仓库里不存二进制 PNG，GitHub Actions 里用 Pillow 现生成，与本地定版几何完全一致。
import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 2048
W = S

img = Image.new('RGB', (S, S), (0, 0, 0))
d = ImageDraw.Draw(img)
bar_h = int(0.054 * W)
ys = [0.395, 0.500, 0.605]
starts = [0.285, 0.335, 0.385]
lengths = [0.430, 0.345, 0.260]
for yc, xs, ln in zip(ys, starts, lengths):
    y0 = int(yc * W - bar_h / 2)
    y1 = int(yc * W + bar_h / 2)
    d.rounded_rectangle([int(xs * W), y0, int((xs + ln) * W), y1], radius=bar_h // 2, fill=(255, 255, 255))

icon = img.resize((1024, 1024), Image.LANCZOS)
out = os.path.join(ROOT, 'DolbyPlayer', 'Assets.xcassets', 'AppIcon.appiconset', 'AppIcon-1024.png')
icon.save(out)
print('wrote', out)
