# ShyFoss

blurs your mac when you look away, clears when you look back. reads the head tracking sensors in AirPods 3/Pro/Max. free software clone of [ShyGlass](https://shyglass.app)

```
brew install dappermint/tap/shyfoss
```

or `make run`. macOS 14+, one swift file, no dependencies

1. first launch asks you to look at the screen center and calibrate
2. turn further than the comfort zone (default 15°) and the screen fades to blur over the next 18°
3. look back and it clears. esc clears it too until you return to center
4. settings… in the menu bar: comfort zone, fade distance, blur strength. recenter with ⌘r

nothing leaves your mac. the blur is a plain `NSVisualEffectView`, no screen recording permission needed

MIT
