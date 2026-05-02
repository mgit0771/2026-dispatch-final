# Decision Framework

Krótki operator cheat sheet dla wyboru między single, parallel i multi-turn.

## Decision tree

```text
Masz 1 task czy kilka?
|
+- 1 task
|  |
|  +- miesci sie w 1 turnie workera?
|  |  |
|  |  +- tak  -> F3 / dispatch-loop-hardened.sh
|  |  +- nie  -> multi-turn worker (outline -> expand)
|  |
|  +- merge wymaga recznego gate?
|     |
|     +- tak  -> mode=gate
|     +- nie  -> mode=auto tylko za swiadoma zgoda ownera
|
+- 2-5 niezaleznych taskow
   |
   +- wspolny review context ma sens?
      |
      +- tak  -> F4 / dispatch-batch-hardened.sh
      +- nie  -> kilka osobnych F3
```

## When to use what

- `F3` używaj dla 1 workera / 1 PR / małego lub średniego scope.
- `F4` używaj dla `2-5` podobnych PR-ów, gdy batch CCC da oszczędność.
- Multi-turn worker używaj tylko wtedy, gdy jedno zadanie realnie nie mieści się
  w 1 turnie albo owner chce outline-review-expand.

## Cost and wall summary

- Single worker + multi-turn CCC: około `35 min`, `~$2-3`.
- Parallel 3 workers + batch CCC: około `23 min`, `~$3-5` total.
- R3 batch dawał około `$0.28 / PR` CCC vs `~$0.91 / PR` w single flow.
- Same-session CCC merge dawał około `35-40%` oszczędności vs fresh Turn 2.

## `gate` vs `auto`

- `gate` to default dla kodu, integracji i wszystkiego, co nie jest disposable.
- `auto` tylko dla disposable repo albo gdy owner jawnie akceptuje ryzyko.
- W hardened F2 `FAIL` blokuje merge zawsze.
- W batchu auto powinno merge'ować tylko `PASS`; `WARN` i `FAIL` raportuj jako skipped.

## Rule of thumb

- 1 PR -> F3
- 2-5 podobnych PR-ów -> F4
- 1 duży task -> multi-turn worker
- kod / bezpieczeństwo / produkcja -> `gate`
- szybki disposable docs run -> można rozważyć `auto`
