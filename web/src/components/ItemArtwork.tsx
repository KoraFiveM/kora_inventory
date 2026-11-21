import { useContext, useEffect, useMemo, useState } from "react"
import { UiConfigContext } from "@/context"
import { artworkCandidates } from "@/lib/artwork"
import type { InventoryItem } from "@/lib/types"

export function ItemArtwork({ item, className }: { item: Pick<InventoryItem, "name" | "label" | "image" | "imageOverride">; className: string }) {
    const { images } = useContext(UiConfigContext)
    const candidates = useMemo(() => artworkCandidates(item, images), [item.name, item.image, item.imageOverride, images])
    const [attempt, setAttempt] = useState(0)

    // A different item in the same slot is a different candidate list, so the
    // attempt counter has to go back to the start or the new item inherits the
    // old one's failures and shows the letter placeholder.
    useEffect(() => { setAttempt(0) }, [candidates])

    const source = candidates[attempt]

    return <span className={className}>{source
        ? <img key={source} src={source} alt="" onError={() => setAttempt((current) => current + 1)} />
        : (item.label ?? item.name).slice(0, 1)}</span>
}
