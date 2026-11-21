import type { InventoryItem, UiConfig } from "@/lib/types"

/**
 * Item name -> a safe `nui://` URL, or undefined.
 *
 * Item records reach the browser from shared item definitions any resource can
 * extend, so a name is untrusted text on the way into an `src`. Anything but a
 * plain identifier is rejected outright rather than escaped -- item names are
 * already constrained to that shape, so there is nothing legitimate to lose.
 */
function localImageUrl(base: string | undefined, name: string, extension: string) {
    if (!base) return undefined
    if (!/^[a-z0-9_-]+$/i.test(name)) return undefined
    if (!/^[a-z0-9]+$/i.test(extension)) return undefined
    return `${base.replace(/\/+$/, "")}/${name}.${extension}`
}

/**
 * Every URL worth trying for one item's artwork, best first.
 *
 * Ordered rather than probed: there is no way to ask whether a `nui://` file
 * exists without requesting it, and an `<img onError>` chain gets that for free
 * with no HEAD requests and no manifest to keep in sync.
 */
function localArtworkCandidates(image: string, images: NonNullable<UiConfig["images"]>) {
    const filename = image.split(/[\\/]/).pop() ?? ""
    const extension = /\.([a-z0-9]+)$/i.exec(filename)?.[1]
    const name = extension ? filename.slice(0, -(extension.length + 1)) : filename
    if (!name) return []

    const extensions = extension ? [extension] : images.extensions ?? []
    return extensions
        .map((candidate) => localImageUrl(images.localPath, name, candidate))
        .filter((url): url is string => Boolean(url))
}

export function artworkCandidates(item: Pick<InventoryItem, "name" | "image" | "imageOverride">, images: NonNullable<UiConfig["images"]>) {
    const image = typeof item.image === "string" ? item.image : ""

    // info.image is the only per-item setting that may point outside the local
    // image folder. Preserve a full URL exactly as the item supplied it.
    if (item.imageOverride && (image.startsWith("https://") || image.startsWith("nui://"))) {
        return [image]
    }

    // A filename in info.image replaces the definition filename, but stays
    // under kora_inventory/images. Normal items use their definition filename.
    if (item.imageOverride && image) {
        return localArtworkCandidates(image, images)
    }

    const candidates = image ? localArtworkCandidates(image, images) : []
    for (const extension of images.extensions ?? []) {
        const url = localImageUrl(images.localPath, item.name, extension)
        if (url && !candidates.includes(url)) candidates.push(url)
    }
    return candidates
}
