# ColdFusion 2023 / 2025: concurrent writes to `getMetadata()` structs permanently break a component

Right after a ColdFusion restart, two requests that add keys to the same component's metadata at
the same time (as an ORM like Quick does the first time it builds an entity) can corrupt it. From
then on, every request that uses that component fails until ColdFusion is restarted again:

```
java.lang.NullPointerException: Cannot invoke "coldfusion.util.Key.getKeyString()" because "this.key" is null
	at coldfusion.util.CaseInsensitiveMap$ScopeIterator$ScopeEntry.getKey(CaseInsensitiveMap.java:482)
	at coldfusion.runtime.ObjectDuplicator._duplicate(ObjectDuplicator.java:156)
	...
	at coldfusion.runtime.CFPage.Duplicate(CFPage.java:10906)
```

Often alongside: `Element NAME is undefined in PROP.`

Adobe has confirmed this as a ColdFusion bug, **CF-4234842**, and is fixing it. If it affects you,
ask Adobe support about CF-4234842.

> **Our fix is withdrawn.** An earlier version of this README offered a fix. It has side effects
> (for example, `structCopy()` of component metadata changes the original), and ColdFusion may not
> start if it is still installed when Adobe's fix arrives. If you installed it,
> [remove it](#remove-our-fix).

## Reproduce

With [CommandBox](https://www.ortussolutions.com/products/commandbox):

```
box server start serverConfigFile=server-2023.json
```

Then open <http://127.0.0.1:61230/index.cfm> once. For 2025, use `server-2025.json` and port 61250.

On a normal ColdFusion install: copy the `app` folder into your web root as `npe-repro`, restart
ColdFusion, and open <http://localhost:8500/npe-repro/index.cfm> once. ColdFusion needs write
access to `npe-repro/gen`.

Expected on a freshly started server:

```
burst errors:  80 of 100 calls
   16 x Element NAME is undefined in PROP.
   64 x Cannot invoke "coldfusion.util.Key.getKeyString()" because "this.key" is null
after burst:   8 of 10 components still fail on every call
result:        FAIL
```

The page writes 10 new components, then 10 threads do what an ORM does on first use:

```cfml
var md = getMetadata( createObject( "component", path ) );
for ( var prop in md.properties ) {
	param prop.column = prop.name;   // add default keys to each property struct
}
duplicate( md );
```

`index.cfm?mode=struct` does the same writes into ordinary structs and always passes. Add
`?trace=1` for the full Java stack. If you don't restart first, reload a few times: about one
reload in five fails.

## Results

Fresh restart before every run (`repro.ps1 -FreshStart`), no framework, no database:

| Server | Runs that failed | Components left broken |
|---|---|---|
| 2023 Update 26 | **10 of 10** | **53 of 100** |
| 2025 Update 14 | **10 of 10** | **60 of 100** |

Updates 25 and 13 behave the same.

## Why

- `getMetadata()` returns the engine's own metadata structs, shared by every request.
- Unlike ordinary CFML structs, they are backed by a plain `java.util.HashMap`, which is not safe
  for concurrent writes. Two requests adding keys at once can lose a key and leave the map's size
  larger than its entries.
- Every later loop over that map, including `duplicate()`, hits an empty slot and throws the NPE,
  for as long as the JVM runs.
- It happens at startup because keys are only added the first time.

## Remove our fix

On every ColdFusion instance where you installed it:

1. Stop ColdFusion.
2. Delete `hf202300-00001-casemap-fix.jar` (2023) or `hf202500-00001-casemap-fix.jar` (2025) from
   the instance's `lib\updates` folder, for example `C:\ColdFusion2023\cfusion\lib\updates`. On
   CommandBox the folder is `WEB-INF\cfusion\lib\updates` under the server's home
   (`box server info property=serverHomeDirectory`).
3. Start ColdFusion.

To check, open `app/build-info.cfm` on that server: it should say `our fix installed: no`.

The fix's code stays in `fix/` so the results can be checked on the repo's `-fixed` test servers
(`repro.ps1 -Setup`). Don't install it anywhere else.
