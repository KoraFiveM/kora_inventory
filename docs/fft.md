---
title: FFT hooks
sidebar_position: 9
---

# Optional FFT hooks

Companion resource `fft` can drive inventory scenarios (for example vending purchases). It is optional and off by default.

Enable before starting inventory:

```cfg
setr fft_kora_hooks true
```

`fft_hooks.lua` is the last client script in the manifest and returns immediately unless the convar `fft_kora_hooks` is `true`. No other Lua file references FFT. When enabled it owns the FFT exports, the NUI reply callbacks `fft:result` and `fft:observed`, and session synchronisation (state bag `fftSession`). The browser half lives in `web/src/lib/fft.ts` and `data-fft-*` attributes and stays inert without an authorised session. Changing the convar needs a restart of kora_inventory.

Client exports: `fftVersion()` returns protocol `1`; `fftAction(action, item, amount)` accepts calls only from `fft` during an active session. Actions include `dragBuy`, `buyReady`, `quantity` and `buy`; unsupported actions fail. Requests correlate the FFT session, the inventory lease token and a request id with a two-second reply timeout. A browser acknowledgement does not prove a purchase; assert the post-commit server receipt and the authoritative inventory and cash change.

Use a disposable development server: runs reset the test character and restock shared vending stock. Install compatible target hooks and select `fft_adapter kora` for FFT's vending suite. Do not commit personal ACE grants, server addresses, reports or recordings. See `FFT.md` in the repository root.
