# ImageKit (SwiftUI) — Zero‑dependency image loader & cache

A tiny Swift Package with **persistent disk cache**, **memory cache**, **ETag/Last‑Modified** validation,
**downsampling**, in‑flight request **coalescing**, and a custom **`AsyncImageView(url:placeholder:)`**.

- **No third‑party SDKs**. Pure Swift + Foundation/UIKit.
- **SwiftUI‑first**. Just drop `AsyncImageView` into your views.
- **Cache persists across app launches** (stored in Application Support, excluded from backup).

## Installation (Swift Package Manager)
1. In Xcode: **File → Add Packages… →** paste this repo URL.
2. Select the **ImageKit** product for your app target.

## Quick Start
```swift
import ImageKit

struct Card: View {
  var body: some View {
    AsyncImageView(
      url: URL(string: "https://picsum.photos/800"),
      placeholder: { ProgressView() }
    )
    .frame(width: 220, height: 140)
    .clipped()
  }
}
```

### Manual cache invalidation
```swift
// Clear both memory and disk caches
Task { await ImageKit.shared.invalidateAll() }

// Evict a single URL (disk) + clear memory cache
Task { await ImageKit.shared.invalidate(url: URL(string: "https://picsum.photos/800")!) }
```

### Notes
- Minimum: **iOS 15 / tvOS 15 / macCatalyst 15** (uses `async/await`).
- Disk cache at `Application Support/ImageKitCache` (excluded from backup).
- Pass a realistic view size so decoding is **downsampled** and memory stays low.

## License
[MIT](./LICENSE)
