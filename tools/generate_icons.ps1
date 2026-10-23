Add-Type -AssemblyName System.Drawing

$converterCode = @"
using System;
using System.Drawing;
using System.Drawing.Imaging;

public class SvgProcessor {
    public static void ProcessImage(string srcPath, string dstPath, int targetSize) {
        using (Bitmap src = new Bitmap(srcPath)) {
            int minX = src.Width, maxX = 0, minY = src.Height, maxY = 0;
            for (int y = 0; y < src.Height; y++) {
                for (int x = 0; x < src.Width; x++) {
                    Color c = src.GetPixel(x, y);
                    if (c.R > 20 || c.G > 20 || c.B > 20) {
                        if (x < minX) minX = x;
                        if (x > maxX) maxX = x;
                        if (y < minY) minY = y;
                        if (y > maxY) maxY = y;
                    }
                }
            }

            int w = (maxX >= minX) ? (maxX - minX + 1) : src.Width;
            int h = (maxY >= minY) ? (maxY - minY + 1) : src.Height;
            if (minX > maxX) { minX = 0; minY = 0; w = src.Width; h = src.Height; }

            using (Bitmap cropped = new Bitmap(w, h, PixelFormat.Format32bppArgb)) {
                for (int y = 0; y < h; y++) {
                    for (int x = 0; x < w; x++) {
                        Color c = src.GetPixel(minX + x, minY + y);
                        int alpha = Math.Max(c.R, Math.Max(c.G, c.B));
                        cropped.SetPixel(x, y, Color.FromArgb(alpha, 255, 255, 255));
                    }
                }

                using (Bitmap result = new Bitmap(targetSize, targetSize, PixelFormat.Format32bppArgb)) {
                    using (Graphics g = Graphics.FromImage(result)) {
                        g.Clear(Color.FromArgb(0, 0, 0, 0));
                        g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.HighQuality;
                        g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;

                        int pad = Math.Max(2, (int)(targetSize * 0.08f));
                        float scale = Math.Min((float)(targetSize - pad * 2) / w, (float)(targetSize - pad * 2) / h);
                        float rw = w * scale;
                        float rh = h * scale;
                        float rx = (targetSize - rw) / 2f;
                        float ry = (targetSize - rh) / 2f;

                        g.DrawImage(cropped, rx, ry, rw, rh);
                    }
                    result.Save(dstPath, ImageFormat.Png);
                }
            }
        }
    }
}
"@

Add-Type -TypeDefinition $converterCode -ReferencedAssemblies System.Drawing

function Convert-Svg($svgFile, $dstFile, $size) {
    $svgText = Get-Content -Path $svgFile -Raw
    $svgText = $svgText -replace 'fill="#000000"', 'fill="#FFFFFF"'
    if ($svgText -notmatch 'fill=') {
        $svgText = $svgText -replace '<path', '<path fill="#FFFFFF"'
    }

    $html = @"
<!DOCTYPE html>
<html>
<head>
<style>
  * { margin: 0; padding: 0; }
  html, body { width: 512px; height: 512px; background: #000000; overflow: hidden; display: flex; align-items: center; justify-content: center; }
  svg { width: 440px; height: 440px; }
  path { fill: #FFFFFF !important; }
</style>
</head>
<body>
$svgText
</body>
</html>
"@
    $tmpHtml = "$env:TEMP\svg_tmp_$size.html"
    $tmpPng = "$env:TEMP\svg_tmp_$size.png"
    Set-Content -Path $tmpHtml -Value $html -Encoding UTF8

    $p = Start-Process -FilePath "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" -ArgumentList "--headless=new --window-size=512,512 --screenshot=`"$tmpPng`" `"file:///$($tmpHtml.Replace('\','/'))`"" -PassThru -Wait
    
    [SvgProcessor]::ProcessImage($tmpPng, $dstFile, $size)
    Write-Output "Successfully wrote $dstFile ($size x $size)"
}

$iconDir = "d:\Antigravity\BeamNG mod\CareerSplitScreen\art\icons"
if (-not (Test-Path $iconDir)) {
    New-Item -ItemType Directory -Force -Path $iconDir | Out-Null
}

$currencySvg = "D:\SteamLibrary\steamapps\common\BeamNG.drive\ui\ui-vue\src\assets\fonts\bngIcons\svg\beamCurrency.svg"
$syncSvg = "D:\SteamLibrary\steamapps\common\BeamNG.drive\ui\ui-vue\src\assets\fonts\bngIcons\svg\sync.svg"

Convert-Svg $currencySvg "$iconDir\beamCurrency.png" 64
Convert-Svg $syncSvg "$iconDir\refreshIcon.png" 64
