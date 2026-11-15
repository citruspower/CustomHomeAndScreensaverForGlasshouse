# MyGlassHome

Custom Home Launcher for LG TVs running Glasshouse. Download the Zip File, upload it in the Dashboard and select it.

Follow the official documentation when unsure.

https://rorygallagher2024.github.io/glasshouse/dashboard/home/#custom-launcher


Add your weather location

1. Get coordinates: In Google Maps, right-click your town and click the numbers to copy them. Round both to 2 decimals. For Berlin that's 52.52, 13.40.
2. Open the file: Unzip the folder. Open index.html in TextEdit (Mac) or Notepad (Windows), not in the browser.
3. Find the line: Press ⌘F or Ctrl+F and search for var WEATHER = null;
4. Replace null with your numbers, like this:
var WEATHER = { lat: 52.52, lon: 13.40 };
5. Save and reload the page.

If no weather shows up, check that you kept the commas, the { } brackets and the ; at the end. To turn the weather off again, change it back to null.


# Starry Sky

The screensaver is a true-black night sky full of shimmering stars, the Milky Way, the odd distant shooting star, a 24h clock drawn in stars that moves to a new spot every 10 minutes, and a slow camera pan to a brand-new sky every 30 to 40 minutes. Made for OLED.

To install, paste this into your terminal and change the IP adresses and paths.

`scp -r /Users/path/to/starry-sky root@192.168.1.2:/var/lib/tvweb/screensavers/   `

# Project Screenshots

<div align="center">
  <img src="images/MyGlassHome.png" width="45%" alt="MyGlassHome">
  &nbsp;
  <img src="images/starry-sky.png" width="45%" alt="Starry Sky">
</div>