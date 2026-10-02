Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ------------------------------------------------------------
# Einstellungen
# ------------------------------------------------------------

$sampleWidth = 120
$sampleHeight = 68

# Pixel unterhalb dieser Helligkeit ignorieren
$minimumBrightness = 18

# Grau, Weiß und schwach gefärbte Pixel ignorieren
# Wertebereich: 0.0 bis 1.0
$minimumSaturation = 0.18

# Anzahl der Farbton-Gruppen
# 24 Gruppen entsprechen jeweils 15 Grad
$hueBucketCount = 24

# Mindestanzahl relevanter Pixel
$minimumRelevantPixels = 5

# Optional: Bildschirmrand ignorieren
# 0.05 bedeutet jeweils 5 Prozent Rand
$cropPercent = 0.05

# ------------------------------------------------------------
# Initialisierung
# ------------------------------------------------------------

$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

$screenshot = $null
$screenshotGraphics = $null
$sample = $null
$sampleGraphics = $null

try {
    # Screenshot erstellen
    $screenshot = New-Object System.Drawing.Bitmap(
        $bounds.Width,
        $bounds.Height
    )

    $screenshotGraphics = [System.Drawing.Graphics]::FromImage(
        $screenshot
    )

    $screenshotGraphics.CopyFromScreen(
        $bounds.X,
        $bounds.Y,
        0,
        0,
        $bounds.Size
    )

    # Screenshot verkleinern
    $sample = New-Object System.Drawing.Bitmap(
        $sampleWidth,
        $sampleHeight
    )

    $sampleGraphics = [System.Drawing.Graphics]::FromImage(
        $sample
    )

    $sampleGraphics.InterpolationMode =
        [System.Drawing.Drawing2D.InterpolationMode]::Low

    $sampleGraphics.DrawImage(
        $screenshot,
        0,
        0,
        $sampleWidth,
        $sampleHeight
    )

    # Zu analysierenden Bereich bestimmen
    [int]$cropX = $sampleWidth * $cropPercent
    [int]$cropY = $sampleHeight * $cropPercent

    [int]$startX = $cropX
    [int]$endX = $sampleWidth - $cropX

    [int]$startY = $cropY
    [int]$endY = $sampleHeight - $cropY

    # Farbton-Gruppen
    $hueBuckets = @{}

    [int]$relevantPixelCount = 0

    # --------------------------------------------------------
    # Pixel analysieren
    # --------------------------------------------------------

    for ($x = $startX; $x -lt $endX; $x++) {
        for ($y = $startY; $y -lt $endY; $y++) {
            $pixel = $sample.GetPixel($x, $y)

            [int]$red = $pixel.R
            [int]$green = $pixel.G
            [int]$blue = $pixel.B

            [int]$maximum = $red

            if ($green -gt $maximum) {
                $maximum = $green
            }

            if ($blue -gt $maximum) {
                $maximum = $blue
            }

            [int]$minimum = $red

            if ($green -lt $minimum) {
                $minimum = $green
            }

            if ($blue -lt $minimum) {
                $minimum = $blue
            }

            # Dunkle Pixel, insbesondere Schwarz, ignorieren
            if ($maximum -lt $minimumBrightness) {
                continue
            }

            [int]$delta = $maximum - $minimum

            if ($delta -le 0) {
                continue
            }

            [double]$saturation = $delta / [double]$maximum

            # Grau, Weiß und schwach gefärbte Pixel ignorieren
            if ($saturation -lt $minimumSaturation) {
                continue
            }

            # Farbton von 0 bis 360 berechnen
            [double]$hue = 0.0

            if ($maximum -eq $red) {
                $hue = 60.0 * (($green - $blue) / [double]$delta)

                if ($hue -lt 0.0) {
                    $hue = $hue + 360.0
                }
            }
            elseif ($maximum -eq $green) {
                $hue = 60.0 * (
                    (($blue - $red) / [double]$delta) + 2.0
                )
            }
            else {
                $hue = 60.0 * (
                    (($red - $green) / [double]$delta) + 4.0
                )
            }

            # Rot liegt sowohl bei 0 als auch bei 360 Grad.
            # Durch die halbe Gruppenbreite werden beide Bereiche
            # in dieselbe Farbgruppe verschoben.
            [double]$bucketWidth = 360.0 / $hueBucketCount
            [double]$shiftedHue = $hue + ($bucketWidth / 2.0)

            if ($shiftedHue -ge 360.0) {
                $shiftedHue = $shiftedHue - 360.0
            }

            [int]$bucketIndex = $shiftedHue / $bucketWidth

            if ($bucketIndex -ge $hueBucketCount) {
                $bucketIndex = 0
            }

            $bucketKey = $bucketIndex.ToString()

            if (-not $hueBuckets.ContainsKey($bucketKey)) {
                $hueBuckets[$bucketKey] = @{
                    Count = [long]0
                    WeightTotal = [double]0.0
                    RedWeighted = [double]0.0
                    GreenWeighted = [double]0.0
                    BlueWeighted = [double]0.0
                }
            }

            # Gesättigte und helle Farben stärker gewichten
            [double]$brightness = $maximum / 255.0
            [double]$weight = (
                $saturation *
                $saturation *
                $brightness
            )

            $bucket = $hueBuckets[$bucketKey]

            $bucket.Count = $bucket.Count + 1
            $bucket.WeightTotal = $bucket.WeightTotal + $weight
            $bucket.RedWeighted = $bucket.RedWeighted + ($red * $weight)
            $bucket.GreenWeighted = $bucket.GreenWeighted + ($green * $weight)
            $bucket.BlueWeighted = $bucket.BlueWeighted + ($blue * $weight)

            $relevantPixelCount = $relevantPixelCount + 1
        }
    }

    # --------------------------------------------------------
    # Prüfen, ob eine Farbe gefunden wurde
    # --------------------------------------------------------

    if ($hueBuckets.Count -eq 0) {
        Write-Output "#000000"
        return
    }

    if ($relevantPixelCount -lt $minimumRelevantPixels) {
        Write-Output "#000000"
        return
    }

    # --------------------------------------------------------
    # Dominante Farbton-Gruppe bestimmen
    # --------------------------------------------------------

    $dominantBucket = $null
    [double]$dominantWeight = -1.0

    foreach ($bucket in $hueBuckets.Values) {
        if ($bucket.WeightTotal -gt $dominantWeight) {
            $dominantWeight = $bucket.WeightTotal
            $dominantBucket = $bucket
        }
    }

    if ($null -eq $dominantBucket) {
        Write-Output "#000000"
        return
    }

    if ($dominantBucket.WeightTotal -le 0.0) {
        Write-Output "#000000"
        return
    }

    # --------------------------------------------------------
    # Gewichteten RGB-Wert der dominanten Farbe berechnen
    # --------------------------------------------------------

    [int]$dominantRed =
        $dominantBucket.RedWeighted /
        $dominantBucket.WeightTotal

    [int]$dominantGreen =
        $dominantBucket.GreenWeighted /
        $dominantBucket.WeightTotal

    [int]$dominantBlue =
        $dominantBucket.BlueWeighted /
        $dominantBucket.WeightTotal

    if ($dominantRed -lt 0) {
        $dominantRed = 0
    }

    if ($dominantRed -gt 255) {
        $dominantRed = 255
    }

    if ($dominantGreen -lt 0) {
        $dominantGreen = 0
    }

    if ($dominantGreen -gt 255) {
        $dominantGreen = 255
    }

    if ($dominantBlue -lt 0) {
        $dominantBlue = 0
    }

    if ($dominantBlue -gt 255) {
        $dominantBlue = 255
    }

    # --------------------------------------------------------
    # Sättigung für LED-Streifen verstärken
    # --------------------------------------------------------

    [int]$finalMaximum = $dominantRed

    if ($dominantGreen -gt $finalMaximum) {
        $finalMaximum = $dominantGreen
    }

    if ($dominantBlue -gt $finalMaximum) {
        $finalMaximum = $dominantBlue
    }

    [int]$finalMinimum = $dominantRed

    if ($dominantGreen -lt $finalMinimum) {
        $finalMinimum = $dominantGreen
    }

    if ($dominantBlue -lt $finalMinimum) {
        $finalMinimum = $dominantBlue
    }

    # Niedrigsten Kanal abziehen.
    # Dadurch wird die Farbe kräftiger.
    $dominantRed = $dominantRed - $finalMinimum
    $dominantGreen = $dominantGreen - $finalMinimum
    $dominantBlue = $dominantBlue - $finalMinimum

    # Wieder auf die ursprüngliche Maximalhelligkeit skalieren
    [int]$newMaximum = $dominantRed

    if ($dominantGreen -gt $newMaximum) {
        $newMaximum = $dominantGreen
    }

    if ($dominantBlue -gt $newMaximum) {
        $newMaximum = $dominantBlue
    }

    if ($newMaximum -gt 0) {
        $dominantRed =
            $dominantRed * $finalMaximum / $newMaximum

        $dominantGreen =
            $dominantGreen * $finalMaximum / $newMaximum

        $dominantBlue =
            $dominantBlue * $finalMaximum / $newMaximum
    }

    # --------------------------------------------------------
    # Hexwert ausgeben
    # --------------------------------------------------------

    $hexRed = $dominantRed.ToString("X2")
    $hexGreen = $dominantGreen.ToString("X2")
    $hexBlue = $dominantBlue.ToString("X2")

    Write-Output ("#" + $hexRed + $hexGreen + $hexBlue)
}
catch {
    Write-Output "#000000"
}
finally {
    if ($sampleGraphics -ne $null) {
        $sampleGraphics.Dispose()
    }

    if ($screenshotGraphics -ne $null) {
        $screenshotGraphics.Dispose()
    }

    if ($sample -ne $null) {
        $sample.Dispose()
    }

    if ($screenshot -ne $null) {
        $screenshot.Dispose()
    }
}