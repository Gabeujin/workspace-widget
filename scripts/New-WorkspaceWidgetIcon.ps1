[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$SourcePng,

  [Parameter(Mandatory)]
  [string]$OutputPng,

  [Parameter(Mandatory)]
  [string]$OutputIco
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

function New-ResizedPngBytes {
  param(
    [Parameter(Mandatory)]
    [System.Drawing.Image]$Source,

    [Parameter(Mandatory)]
    [int]$Size
  )

  $bitmap = [System.Drawing.Bitmap]::new(
    $Size,
    $Size,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
  )

  try {
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
      $graphics.Clear([System.Drawing.Color]::Transparent)
      $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
      $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
      $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
      $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
      $graphics.DrawImage($Source, 0, 0, $Size, $Size)
    }
    finally {
      $graphics.Dispose()
    }

    $stream = [System.IO.MemoryStream]::new()
    try {
      $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
      return $stream.ToArray()
    }
    finally {
      $stream.Dispose()
    }
  }
  finally {
    $bitmap.Dispose()
  }
}

$source = [System.Drawing.Bitmap]::FromFile((Resolve-Path -LiteralPath $SourcePng))
try {
  $minX = $source.Width
  $minY = $source.Height
  $maxX = -1
  $maxY = -1

  for ($y = 0; $y -lt $source.Height; $y++) {
    for ($x = 0; $x -lt $source.Width; $x++) {
      if ($source.GetPixel($x, $y).A -gt 8) {
        if ($x -lt $minX) { $minX = $x }
        if ($y -lt $minY) { $minY = $y }
        if ($x -gt $maxX) { $maxX = $x }
        if ($y -gt $maxY) { $maxY = $y }
      }
    }
  }

  if ($maxX -lt $minX -or $maxY -lt $minY) {
    throw "The source image does not contain visible pixels: $SourcePng"
  }

  $contentWidth = $maxX - $minX + 1
  $contentHeight = $maxY - $minY + 1
  $contentSide = [Math]::Max($contentWidth, $contentHeight)
  $cropPadding = [Math]::Ceiling($contentSide * 0.04)
  $cropSide = $contentSide + (2 * $cropPadding)
  $centerX = ($minX + $maxX) / 2.0
  $centerY = ($minY + $maxY) / 2.0
  $cropX = [Math]::Floor($centerX - ($cropSide / 2.0))
  $cropY = [Math]::Floor($centerY - ($cropSide / 2.0))

  $cropX = [Math]::Max(0, [Math]::Min($cropX, $source.Width - $cropSide))
  $cropY = [Math]::Max(0, [Math]::Min($cropY, $source.Height - $cropSide))
  $cropSide = [Math]::Min($cropSide, [Math]::Min($source.Width - $cropX, $source.Height - $cropY))

  $master = [System.Drawing.Bitmap]::new(
    1024,
    1024,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
  )

  try {
    $graphics = [System.Drawing.Graphics]::FromImage($master)
    try {
      $graphics.Clear([System.Drawing.Color]::Transparent)
      $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
      $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
      $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
      $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality

      $sourceRectangle = [System.Drawing.RectangleF]::new($cropX, $cropY, $cropSide, $cropSide)
      $destinationRectangle = [System.Drawing.RectangleF]::new(0, 0, 1024, 1024)
      $graphics.DrawImage(
        $source,
        $destinationRectangle,
        $sourceRectangle,
        [System.Drawing.GraphicsUnit]::Pixel
      )
    }
    finally {
      $graphics.Dispose()
    }

    $outputPngDirectory = Split-Path -Parent $OutputPng
    $outputIcoDirectory = Split-Path -Parent $OutputIco
    [System.IO.Directory]::CreateDirectory($outputPngDirectory) | Out-Null
    [System.IO.Directory]::CreateDirectory($outputIcoDirectory) | Out-Null

    $master.Save($OutputPng, [System.Drawing.Imaging.ImageFormat]::Png)

    $sizes = @(16, 20, 24, 32, 40, 48, 64, 96, 128, 256)
    $frames = foreach ($size in $sizes) {
      [pscustomobject]@{
        Size = $size
        Bytes = New-ResizedPngBytes -Source $master -Size $size
      }
    }

    $stream = [System.IO.File]::Open(
      $OutputIco,
      [System.IO.FileMode]::Create,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::None
    )

    try {
      $writer = [System.IO.BinaryWriter]::new($stream)
      try {
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$frames.Count)

        $offset = 6 + (16 * $frames.Count)
        foreach ($frame in $frames) {
          $dimension = if ($frame.Size -eq 256) { 0 } else { $frame.Size }
          $writer.Write([byte]$dimension)
          $writer.Write([byte]$dimension)
          $writer.Write([byte]0)
          $writer.Write([byte]0)
          $writer.Write([uint16]1)
          $writer.Write([uint16]32)
          $writer.Write([uint32]$frame.Bytes.Length)
          $writer.Write([uint32]$offset)
          $offset += $frame.Bytes.Length
        }

        foreach ($frame in $frames) {
          $writer.Write([byte[]]$frame.Bytes)
        }
      }
      finally {
        $writer.Dispose()
      }
    }
    finally {
      $stream.Dispose()
    }

    [pscustomobject]@{
      source = (Resolve-Path -LiteralPath $SourcePng).Path
      outputPng = (Resolve-Path -LiteralPath $OutputPng).Path
      outputIco = (Resolve-Path -LiteralPath $OutputIco).Path
      sourceBounds = @{
        x = $minX
        y = $minY
        width = $contentWidth
        height = $contentHeight
      }
      iconSizes = $sizes
    }
  }
  finally {
    $master.Dispose()
  }
}
finally {
  $source.Dispose()
}
