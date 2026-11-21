export function DurabilityBar({ value }: { value: number }) {
    return <span className="durability"><i style={{ width: `${Math.max(0, Math.min(100, value))}%` }} /></span>
}
