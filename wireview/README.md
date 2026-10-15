# WireView Pro II setup for TroyMetrics Benchmark Overlays

This makes the **Power Detector** in [TroyMetrics Benchmark Overlays v1.15](https://github.com/TroyMetrics/Benchmark-Overlays) read its per-pin data from a **Thermal Grizzly WireView Pro II** instead of an ASUS ROG Astral GPU. Pin amps, total current, pin balance, and the warning/danger alerts all work with any GPU behind the WireView.

## What you need first

- **MSI Afterburner** with **RivaTuner Statistics Server (RTSS)** ticked during install ([guru3d.com](https://www.guru3d.com))
- **HWiNFO64 8.42 or newer** ([hwinfo.com](https://www.hwinfo.com/download/))
- The WireView's **USB cable connected** to the PC

You don't need to install the TroyMetrics overlays yourself. Setup downloads them if they're missing.

## Setup (about one minute)

1. Download this repository: green **Code** button, then **Download ZIP**, then extract it.
2. Open the `wireview` folder and double-click **`Setup-WireView.bat`**.
   - If Windows says "Windows protected your PC", click **More info**, then **Run anyway**.
   - Click **Yes** when Windows asks for administrator permission.
3. Follow what the window says. It checks everything in order and tells you exactly what to fix if something is missing:

   ```
   >> Looking for RivaTuner Statistics Server (RTSS)
      [OK] C:\Program Files (x86)\RivaTuner Statistics Server
   >> Checking the TroyMetrics overlays
      [OK] Found all 5 Power Detector presets
   >> Checking the Adderley Bold font
      [OK] Already installed
   >> Finding the WireView Pro II in HWiNFO64
      [OK] Thermal Grizzly WireView Pro II (sensor instance 0)
      Live check: Pin 1 = 4.74 A, Total Power = 336.0 W
   >> Creating WireView versions of the presets
      [OK] TroyMetrics 12VHPWR Power Detector (WireView Pro II).ovl
      ...
   ```

4. Turn it on in RTSS: **Setup**, then the **Plugins** tab. Tick **OverlayEditor.dll** and double-click it. Then go to **Layouts**, click **Load**, pick a preset ending in **(WireView Pro II)**, and click **Open**.

Keep HWiNFO64 running while you play. **Run setup again** after updating HWiNFO, reinstalling the overlays, or moving the WireView to another PC.

## If something goes wrong

| Setup says | Fix |
|---|---|
| HWiNFO64 is running but not sharing its sensors | In HWiNFO's sensor window, click the cogwheel (Configure Sensors), then **Main Settings**, and turn on **Shared Memory Support** |
| HWiNFO64 does not see a WireView Pro II | Check the USB cable, **close the Thermal Grizzly WireView app** (only one program can talk to the WireView), and update HWiNFO64 |
| RTSS might read this instead of the WireView | Another device reports a reading with the same name. If the overlay numbers don't match HWiNFO, hide that reading in HWiNFO |

The free HWiNFO64 turns off Shared Memory Support after 12 hours. Re-enable it, or restart HWiNFO.

## What setup changes

- It creates 5 new files next to the originals in `RTSS\Plugins\Client\Overlays`, each ending in `(WireView Pro II).ovl`. **It never modifies the original presets.**
- In each new file, it repoints 7 HWiNFO data sources (6 pin currents plus total power) to the WireView's readings, using the sensor instance it reads from HWiNFO on your PC. Everything else stays byte-for-byte the same.
- If the TroyMetrics overlays are missing, it downloads the official v1.15 release from GitHub, verifies its SHA-256 checksum, and installs it the way the TroyMetrics instructions describe, including the Adderley Bold font.

| Overlay source (name unchanged) | Astral reading | WireView reading |
|---|---|---|
| GPU 12VHPWR Pin1 to Pin6 Current | GPU 12VHPWR Pin*N* Current | Pin *N* Current |
| GPU 12VHPWR Connector Total Power | GPU 12VHPWR Connector Total Power | Total Power |

## For developers

Tests use [Pester 5](https://pester.dev) and run on PowerShell 7 on any OS. The setup script itself targets Windows PowerShell 5.1.

```powershell
Invoke-Pester ./wireview/tests
# Also test against the real v1.15 presets:
$env:TM_V115_OVERLAYS = '<extracted zip>\Program Files (x86)\RivaTuner Statistics Server\Plugins\Client\Overlays'
Invoke-Pester ./wireview/tests
```

All overlay design and artwork is by [TroyMetrics](https://github.com/TroyMetrics/Benchmark-Overlays). This folder only adds the WireView setup.
