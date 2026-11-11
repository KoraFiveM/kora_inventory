// Activated only by an authorised development session. Uses actual DOM controls.
type Action = { request: string; session: string; token: string; action: string; item: string; amount?: number }
let session: string | false = false
let token: string | undefined
function post(name: string, data: unknown) {
    const resource = window.GetParentResourceName?.() ?? 'kora_inventory'
    return fetch(`https://${resource}/${name}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) }).catch(() => undefined)
}
export function visibleControl(element: HTMLElement) {
    const style = getComputedStyle(element)
    const rect = element.getBoundingClientRect()
    return rect.width > 0 && rect.height > 0 && rect.bottom > 0 && rect.right > 0 && rect.top < innerHeight && rect.left < innerWidth &&
        style.display !== 'none' && style.visibility !== 'hidden' && style.opacity !== '0' && !element.closest('[hidden],[inert]')
}
export function uniqueControl(selector: string, item?: string): HTMLElement {
    const matches = Array.from(document.querySelectorAll<HTMLElement>(selector)).filter(el =>
        (item === undefined || el.dataset.fftItem === item) && visibleControl(el))
    if (matches.length !== 1) throw new Error(`Expected one visible control; found ${matches.length}`)
    const el = matches[0]
    if ((el as HTMLButtonElement).disabled || el.getAttribute('aria-disabled') === 'true' || el.dataset.pending === 'true') throw new Error('Control is disabled or pending')
    return el
}
export function executeAction(data: Action) {
    if (!session || data.session !== session || !token || data.token !== token) throw new Error('Stale or unauthorised UI session')
    if (data.action === 'dragBuy') {
        if (data.amount !== 1) throw new Error('A shop drag buys one item')
        const detail = { item: data.item, accepted: false, error: 'Inventory drag handler unavailable' }
        window.dispatchEvent(new CustomEvent('fft:dragBuy', { detail }))
        if (!detail.accepted) throw new Error(detail.error)
    } else if (data.action === 'buy' || data.action === 'buyReady') {
        const el = uniqueControl('[data-fft-kind="buy"]', data.item)
        if (data.amount !== undefined && Number(el.dataset.fftQuantity) !== data.amount) throw new Error('Quantity is not ready')
        if (data.action === 'buy') el.click()
    } else if (data.action === 'quantity') {
        if (!Number.isInteger(data.amount) || data.amount! < 1 || data.amount! > 50) throw new Error('Invalid quantity')
        const buy = uniqueControl('[data-fft-kind="buy"]', data.item)
        if (Number(buy.dataset.fftQuantity) === data.amount) return
        const el = uniqueControl('[data-fft-kind="quantity"]') as HTMLInputElement
        if (data.amount! > Number(el.max)) throw new Error('Quantity exceeds available stock')
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!.call(el, String(data.amount))
        el.dispatchEvent(new Event('input', { bubbles: true }))
        el.dispatchEvent(new Event('change', { bubbles: true }))
    } else throw new Error('Unsupported UI action')
}
window.addEventListener('message', ({ data: message }) => {
    if (message.action === 'fft:session') session = typeof message.data?.session === 'string' ? message.data.session : false
    if (message.action === 'kora_inventory:nui:sessionOpened') token = message.data?.token
    if (message.action === 'kora_inventory:nui:sessionClosed') token = undefined
    if (message.action !== 'fft:action') return
    const data = message.data as Action
    try { executeAction(data); void post('fft:result', { ...data, ok: true }) }
    catch (error) { void post('fft:result', { ...data, ok: false, error: String(error) }) }
})
document.addEventListener('click', event => {
    if (!session) return
    const el = (event.target as HTMLElement)?.closest<HTMLElement>('[data-fft-kind]')
    if (el) void post('fft:observed', { action: el.dataset.fftKind, item: el.dataset.fftItem })
}, true)
