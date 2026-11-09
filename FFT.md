# Optional FFT inventory hooks

Install the companion `fft` resource. Before starting inventory, configure:

```cfg
setr fft_kora_hooks true
```

`client/ui.lua` conditionally loads `fft_hooks.lua` from the resource files.
Disabled by default, this file owns the FFT exports, NUI reply callbacks and
session synchronization. Changing the convar requires restarting inventory to
load or unload its hooks. Inventory does not depend on FFT at normal startup.

The client `fftVersion()` export advertises protocol 1. `fftAction(action, item,
amount)` accepts only calls from `fft` during an active FFT session. Actions
include `dragBuy`, `buyReady`, `quantity` and `buy`; unsupported actions fail.
Requests correlate FFT session, inventory lease token and request ID, with a
two-second reply timeout. Browser acknowledgments do not prove a purchase.
Assert the post-commit server receipt and authoritative inventory/cash delta.
Normal inventory access, revisions and mutation validation remain authoritative.

Install compatible target hooks too and select `fft_adapter kora` for FFT's
vending suite. Follow FFT's README and docs/AUTHORING.md for setup and scenario
registration. Use a disposable development server: Kora runs reset their test
character and restock shared vending stock. Do not commit personal ACE grants,
server addresses, reports or recordings.
