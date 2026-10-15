# ColdFusion 2023 / 2025: concurrent writes to `getMetadata()` structs permanently break a component

`getMetadata()` returns ColdFusion's own, live metadata structs for a component, the same objects
for every request. Unlike every other CFML struct, they are backed by a plain `java.util.HashMap`.
When two requests add keys to one of them at the same time, as an ORM does the first time it sees
an entity, the map is corrupted. From then on, every `duplicate()` or loop over it throws a
`NullPointerException`, on every request, until ColdFusion is restarted.

In production this shows up right after a restart: the first burst of traffic corrupts the
metadata and the site returns HTTP 500 on every page that uses those components until the next
restart.

```
java.lang.NullPointerException: Cannot invoke "coldfusion.util.Key.getKeyString()" because "this.key" is null
	at coldfusion.util.CaseInsensitiveMap$ScopeIterator$ScopeEntry.getKey(CaseInsensitiveMap.java:482)
	at coldfusion.runtime.ObjectDuplicator._duplicate(ObjectDuplicator.java:156)
	at coldfusion.runtime.ObjectDuplicator.duplicate(ObjectDuplicator.java:80)
	at coldfusion.runtime.ArrayUtil.Duplicate(ArrayUtil.java:118)
	at coldfusion.runtime.ObjectDuplicator._duplicate(ObjectDuplicator.java:92)
	at coldfusion.runtime.ObjectDuplicator.duplicate(ObjectDuplicator.java:80)
	at coldfusion.runtime.ObjectDuplicator._duplicate(ObjectDuplicator.java:158)
	at coldfusion.runtime.ObjectDuplicator.duplicate(ObjectDuplicator.java:80)
	at coldfusion.runtime.CFPage.Duplicate(CFPage.java:10906)
```

Often alongside: `Element NAME is undefined in PROP.` (a key lost from the same corrupted map).

Verified on **ColdFusion 2023 Update 25** (2023.0.25.330977, Java 17) and **ColdFusion 2025
Update 13** (2025.0.13.331960, Java 21), both run with CommandBox. No framework, no database.

This is separate from the scope-contamination case
([homestar9/adobe-scope-contamination](https://github.com/homestar9/adobe-scope-contamination));
we found it while testing those hotfixes, and none of them change it.

## Reproduce

Needs [CommandBox](https://www.ortussolutions.com/products/commandbox) (`box`).

```
box server start serverConfigFile=server-2023.json
```

Then open <http://127.0.0.1:61230/index.cfm> once. Expected on a freshly started server:

```
server:        ColdFusion Server 2023,0,25,330977
run:           R670B0E3E0B01FBE4: 10 new components x 12 properties, 10 threads, mode=param
burst errors:  80 of 100 calls
   16 x Element NAME is undefined in PROP.
   64 x Cannot invoke "coldfusion.util.Key.getKeyString()" because "this.key" is null
after burst:   8 of 10 components still fail on every call (Cannot invoke "coldfusion.util.Key.getKeyString()" because "this.key" is null)
result:        FAIL
```

For 2025, use `server-2025.json` and port 61250. Add `?trace=1` to print the full Java stack.

The page writes 10 brand-new components (so their metadata is untouched, as after a restart),
then starts 10 threads together. For each component, every thread does what an ORM does on first
use:

```cfml
var md = getMetadata( createObject( "component", path ) );
for ( var prop in md.properties ) {
	param prop.column     = prop.name;   // add default keys to each property struct
	param prop.persistent = true;
	// ... six more
}
duplicate( md );
```

Afterwards it calls `duplicate( getMetadata( ... ) )` on each component again, one call at a time.
A component whose metadata was corrupted fails on every call, forever.

A fresh server fails every time. On a server that has been running for a while, reload the page a
few times: each reload makes new components, and about one reload in five breaks at least one.

Other modes, for comparison:

| URL | What it does | Result on stock ColdFusion |
|---|---|---|
| `index.cfm` | write default keys into metadata, then `duplicate()` it | FAIL |
| `index.cfm?mode=write` | only the writes, no `duplicate()` during the burst | FAIL (the writes alone corrupt the map) |
| `index.cfm?mode=struct` | the same writes into ordinary CFML structs of the same shape | PASS, every time |

## Results (measured 2026-10-14)

`repro.ps1 -FreshStart` restarts the server (new JVM) before every run.

| Server | Fresh starts | Runs that failed | Components left permanently broken |
|---|---|---|---|
| 2023 Update 25 | 10 | **10** | **62 of 100** |
| 2023 Update 25 + fix | 10 | 0 | 0 of 100 |
| 2025 Update 13 | 10 | **10** | **63 of 100** |
| 2025 Update 13 + fix | 10 | 0 | 0 of 100 |

On servers that had already run for a while (no restart between runs), 10 runs each: stock 2023
failed 2 of 10 and 2025 failed 2 of 10; both fixed servers passed 10 of 10.

## What happens

1. **Metadata is one shared object per class.** `getMetadata()` returns the engine's own
   metadata (`coldfusion.runtime.AttributeCollection`), not a copy. The structs inside it (each
   property, each function) are shared by every request in the JVM.
2. **Those structs use a plain `HashMap`.** `AttributeCollection()` calls
   `CaseInsensitiveMap(int)`, which creates a `java.util.HashMap`. An ordinary CFML struct calls
   `Struct()` → `CaseInsensitiveMap(true)`, which creates `CaseInsensitiveMap$CFConcurrentHashMap`.
   So metadata structs look and behave like any other struct in CFML, but are the only ones that
   are not safe to write from two requests at once.
3. **Two requests add keys at the same time.** `HashMap` is not built for that: a key can be lost
   (`Element NAME is undefined`), and its size count can end up larger than the number of entries
   it holds.
4. **The corruption is permanent.** `CaseInsensitiveMap$ScopeIterator` copies the keys into an
   array sized from `map.size()` (`keySet().toArray(new Key[map.size()])`). With a size count that
   is too big, the array has empty slots, and `ScopeEntry.getKey()` throws the NPE above. That
   happens on every loop over the map, including every `duplicate()`, for as long as the JVM runs.
5. **Why at startup.** Keys are only added the first time; after that the same writes only replace
   values, which `HashMap` survives. A just-started JVM is also slower, which widens the window. So
   the first burst of requests after a restart is when it breaks.

How we hit it: the [Quick ORM](https://github.com/coldbox-modules/quick) runs
`param attr.column = attr.name` (and eleven more) on each property struct from
`getMetadata(this)` the first time each entity is built (`BaseEntity.paramAttribute`), and
`duplicate()`s that metadata when it builds an entity (`BaseEntity.metadataInspection`). After a restart, concurrent requests built the
same entities and the whole site returned 500 until the next restart.

The engine also writes into these maps after handing them out. For example,
`MetadataUtils.getAllProperties` adds a `PROPERTY_STRUCT` key on first use (from
`serializeJSON` of a component), and `TemplateProxy.getRuntimeComponentMetadata` puts a new
`FUNCTIONS` array (and sometimes `extends`) into the shared map each time it runs. We could not
make those alone corrupt a map, but they show the maps are written after other requests can see
them.

## The fix

In `coldfusion.util.CaseInsensitiveMap`, the two default constructors create their map with the
class's own concurrent map instead of `HashMap`:

```java
public CaseInsensitiveMap()             { this.map = new CFConcurrentHashMap();         } // was: new HashMap()
public CaseInsensitiveMap(int capacity) { this.map = new CFConcurrentHashMap(capacity); } // was: new HashMap(capacity)
```

That is the whole change: four bytecode instructions (two `new`, two constructor calls) in one
class. Nothing else in the class or the engine changes.

Why it is safe:

- `CaseInsensitiveMap$CFConcurrentHashMap` already ships in the class. It is the null-safe
  `ConcurrentHashMap` (nulls go through `NULL_PILL`) that the `concurrent=true` constructors
  use, so it is what every ordinary CFML struct already runs on.
- The `map` field is typed `java.util.Map`, so no field or method signature changes, and
  serialization is unaffected.
- A `ConcurrentHashMap` cannot be corrupted by concurrent writes, and its `toArray()` copes with
  a size that changes during the copy.

What it touches: every map built with those two constructors, not only metadata (for example tag
attribute collections and some engine-internal maps). A rough single-threaded check (`speed.cfm`:
creating 20,000 components with accessors, `getMetadata()`, tag calls, struct building and
`duplicate()`, `serializeJSON`) showed no measurable difference between stock and fixed on either
version. That is not a full benchmark.

A narrower change would also cover this case: have `AttributeCollection`'s constructors call
`CaseInsensitiveMap(true, capacity)`. We have not tested that one.

### Build and try the fix

The repository holds no Adobe code. `fix/build-fix.ps1` reads `CaseInsensitiveMap.class` from
your installed engine (from the cumulative update jar when it ships its own copy, as 2025 Update 13
does; otherwise from `cfusion.jar`), patches it with [ASM](https://asm.ow2.io/) 9.7 (downloaded
from Maven Central and hash-checked), checks the two constructors, and drops the one-class jar into
that server's `lib/updates` folder as `hf202300-00001-casemap-fix.jar` (or `hf202500-...`).

```
box server start serverConfigFile=server-2023-fixed.json     # installs the engine
box server stop serverConfigFile=server-2023-fixed.json
.\fix\build-fix.ps1 -ServerHome .engine\acf2023-fixed
box server start serverConfigFile=server-2023-fixed.json
```

Then open <http://127.0.0.1:61231/build-info.cfm> (it should show `CaseInsensitiveMap` loaded from
the fix jar and `fix installed: yes`) and <http://127.0.0.1:61231/index.cfm> (`PASS`). For 2025
use `server-2025-fixed.json`, `.engine\acf2025-fixed` and port 61251. To remove the fix, delete
the jar and restart.

`.\repro.ps1 -Setup` does all of this for the four servers; `.\repro.ps1 -FreshStart` then
produces the results table above.

Without PowerShell, the same steps by hand (JDK 11 or newer):

```
javac -cp asm-9.7.jar:asm-tree-9.7.jar -d build fix/PatchCaseInsensitiveMap.java
java  -cp asm-9.7.jar:asm-tree-9.7.jar:build PatchCaseInsensitiveMap <path>/cfusion.jar hf202300-00001-casemap-fix.jar
# copy the jar into <cfusion>/lib/updates and restart
```

## Files

| File | Purpose |
|---|---|
| `app/index.cfm` | The reproduction. Options: `threads` (10), `classes` (10), `properties` (12), `mode` (`param`, `write`, `struct`), `trace`. |
| `app/build-info.cfm` | Which jar each class was loaded from, and what backs component metadata. |
| `app/speed.cfm` | The rough cost check. |
| `app/ping.cfm` | Answers `ok` once the server is up (used by `repro.ps1`). |
| `fix/PatchCaseInsensitiveMap.java` | The patch: the two default constructors, nothing else. Refuses to run if the class is not the expected shape. |
| `fix/build-fix.ps1` | Builds the fix from a server's own engine jar and installs it. |
| `repro.ps1` | Runs the page against the four servers and prints the results table. |
| `server-2023.json`, `server-2025.json` | Stock servers, ports 61230 and 61250. |
| `server-2023-fixed.json`, `server-2025-fixed.json` | Servers for the fix, ports 61231 and 61251. |

Notes:

- ColdFusion runs at most 10 `cfthread`s at a time by default (Administrator > Server Settings >
  Request Tuning). The page lines its threads up before each component, so asking for more threads
  than that limit makes the run report `INVALID` rather than a false pass.
- The server configs add `-XX:-OmitStackTraceInFastThrow`. Without it, once the JIT has
  compiled the failing code the JVM drops the NPE's message and stack, and production logs fill
  with bare `java.lang.NullPointerException` lines.
- Each run writes new `.cfc` files into `app/gen/`. Delete that folder whenever you like.
