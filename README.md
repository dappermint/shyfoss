# ShyFoss

blurs your mac when you look away, clears when you look back. reads the head tracking sensors in AirPods 3/Pro/Max. free software clone of [ShyGlass](https://shyglass.app)

```
brew install dappermint/tap/shyfoss
```

or `make run`. macOS 14+, one swift file, no dependencies

1. first launch asks you to look at the screen center and calibrate
2. turn further than the comfort zone (default 15°) and the screen fades to blur over the next 18°
3. look back and it clears. esc clears it too until you return to center
4. settings… in the menu bar: a top-down map of the zones with your head as a dot, plus comfort zone, fade distance, blur strength
5. ⌃⌥⌘R recenters, ⌃⌥⌘S toggles the shield (for screen sharing). launch at login lives in the menu
6. second monitor: look at it and pick "add a screen here" (menu or settings), or click where it is on the map and drag to adjust. extra screens survive relaunch; the x next to each removes it

yaw drifts a little since airpods have no compass; the center follows you slowly while you're looking at the screen. take the airpods off and the shield clears within a second

nothing leaves your mac. the blur is a plain `NSVisualEffectView`, no screen recording permission needed

MIT
