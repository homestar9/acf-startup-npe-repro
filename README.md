# ColdFusion 2023 / 2025: concurrent writes to `getMetadata()` structs permanently break a component

`getMetadata()` returns ColdFusion's own, live metadata structs for a component, the same objects
for every request. Unlike every other CFML struct, they are backed by a plain `java.util.HashMap`.
When two requests add keys to one of them at the same time, as an ORM does the first time it sees
an entity, the map is corrupted. From then on, every `duplicate()` or loop over it throws a
`NullPointerException`, on every request, until ColdFusion is restarted.

In production this shows up right after a restart: the first burst of traffic corrupts the
metadata and the site returns HTTP 500 on every page that uses those components until the next
restart.

> **Our fix is withdrawn (2026-11-13). If you installed it, remove it.** Adobe has confirmed
> this as a ColdFusion bug (CF-4234842) and is fixing it. Our fix stops the crash but has side
> effects: for example, `structCopy()` of component metadata changes the original. Remove it
> before you install the ColdFusion update that fixes this bug, or ColdFusion may not start.
> See [Remove our fix](#remove-our-fix) and [why it was withdrawn](#our-fix-withdrawn).

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

Verified on **ColdFusion 2023 Updates 25 and 26** (Java 17) and **ColdFusion 2025 Updates 13
and 14** (Java 21), the latest updates as of 2026-10-16, all run with CommandBox. No framework,
no database.

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

These configs install 2023 Update 25 and 2025 Update 13, because CommandBox does not offer
Update 26 or Update 14 yet. The classes involved are the same in both (see
[Results](#results)).

### On a normal ColdFusion install (no CommandBox)

1. Download this repository as a ZIP (green **Code** button > **Download ZIP**) and unzip it.
2. Copy the `app` folder into your ColdFusion web root and rename it `npe-repro`
   (for example `C:\ColdFusion2023\cfusion\wwwroot\npe-repro`).
3. Restart the ColdFusion service.
4. Open <http://localhost:8500/npe-repro/index.cfm> once (use your server's port if it is not
   8500). You should see `result: FAIL`, with output like the example above.

The page needs no database, no datasource and no Administrator settings. It writes its test
components into `npe-repro/gen`, so ColdFusion needs write access to that folder.

If you open the page without restarting first, reload it up to 10 times: on a server that has
been running for a while, about one reload in five fails.

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

## Results

`repro.ps1 -FreshStart` restarts the server (new JVM) before every run.

| Server | Measured | Fresh starts | Runs that failed | Components left permanently broken |
|---|---|---|---|---|
| 2023 Update 26 | 2026-10-16 | 10 | **10** | **53 of 100** |
| 2023 Update 26 + our fix | 2026-10-16 | 10 | 0 | 0 of 100 |
| 2025 Update 14 | 2026-10-16 | 10 | **10** | **60 of 100** |
| 2025 Update 14 + our fix | 2026-10-16 | 10 | 0 | 0 of 100 |
| 2023 Update 25 | 2026-10-14 | 10 | **10** | **62 of 100** |
| 2023 Update 25 + our fix | 2026-10-14 | 10 | 0 | 0 of 100 |
| 2025 Update 13 | 2026-10-14 | 10 | **10** | **63 of 100** |
| 2025 Update 13 + our fix | 2026-10-14 | 10 | 0 | 0 of 100 |

On servers that had already run for a while (no restart between runs), 10 runs each on Update
25 and Update 13: stock 2023 failed 2 of 10 and 2025 failed 2 of 10; both fixed servers passed
10 of 10.

How Update 26 and Update 14 were tested: CommandBox does not offer them yet, so we took the
update jars from Adobe (`hotfix-026-331018.jar` and `hotfix-014-332029.jar`, MD5 as published)
and put the core update jar inside each (`chf20230026.jar`, `chf20250014.jar`) in place of the
previous one in `lib/updates`. The servers then report builds 331018 and 332029. The update
number in `server.coldfusion.productVersion` still shows 25 and 13, because Adobe's full installer,
which also records the update level, was not run.

The classes involved did not change. 2023 Update 26 does not replace `CaseInsensitiveMap`,
`AttributeCollection` or `ObjectDuplicator`. 2025 Update 14 ships its own `CaseInsensitiveMap` and
`ObjectDuplicator`, byte-for-byte identical to Update 13's.

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

## Our fix (withdrawn)

**Withdrawn on 2026-11-13. Do not install it. If you did, [remove it](#remove-our-fix).**

Our fix changed the two default constructors of `coldfusion.util.CaseInsensitiveMap` to use the
class's own concurrent map instead of `HashMap`:

```java
public CaseInsensitiveMap()             { this.map = new CFConcurrentHashMap();         } // was: new HashMap()
public CaseInsensitiveMap(int capacity) { this.map = new CFConcurrentHashMap(capacity); } // was: new HashMap(capacity)
```

It stops the crash (see [Results](#results)), but it changes every map built with those two
constructors, which Adobe counts at about 150 places in the engine. Adobe's testing found three
side effects, and we confirmed all three on 2023 Update 26 and 2025 Update 14:

- `structCopy()` of a property, function or component metadata struct returns a copy that shares
  its data with the original. Changing the copy changes that component's metadata for every
  request until restart, and nothing reports an error.
- In a metadata struct that holds a null value, ColdFusion's internal stand-in for null shows up
  in its output (`java.lang.Object@...`).
- `objectSave()` of such a struct fails with `NotSerializableException`.

Adobe is fixing the bug in the engine with a narrower change, limited to metadata and tag
attribute structs (`coldfusion.runtime.AttributeCollection`).

The code stays in this repository so the results above can be checked. `fix/build-fix.ps1`
builds the fix from a server's own engine jar with [ASM](https://asm.ow2.io/) and drops it into
that server's `lib/updates` folder; `.\repro.ps1 -Setup` does that for the two `-fixed` test
servers (ports 61231 and 61251), and `.\repro.ps1 -FreshStart` produces the results table. Use it
only on those test servers.

## Remove our fix

If you followed an earlier version of this README, remove the fix from every ColdFusion instance
you installed it on. Do it before you install the ColdFusion update that fixes this bug: with
Adobe's fix and ours both installed, ColdFusion did not start in our tests, and its log showed a
`java.lang.NoSuchMethodError` that mentions `CaseInsensitiveMap.nonNullKeys`. Removing our jar
fixes that too.

1. Stop the ColdFusion service (on CommandBox, `box server stop`).
2. Delete our jar from the instance's `lib\updates` folder:
   - ColdFusion 2023: `hf202300-00001-casemap-fix.jar`
   - ColdFusion 2025: `hf202500-00001-casemap-fix.jar`

   The folder is, for example, `C:\ColdFusion2023\cfusion\lib\updates`. Each instance has its own
   (for example `C:\ColdFusion2023\instance2\lib\updates`). On CommandBox it is
   `<serverHomeDirectory>\WEB-INF\cfusion\lib\updates`; find `serverHomeDirectory` with
   `box server info property=serverHomeDirectory`. Leave every other jar in that folder alone.
3. Start ColdFusion.
4. To check, copy `app\build-info.cfm` into your web root, open it in a browser and look for
   `our fix installed: no`. Then delete that file.

Until Adobe's fix ships, a server without our fix can hit the crash again after a restart. If it
affects you, ask Adobe support about bug CF-4234842.

## Files

| File | Purpose |
|---|---|
| `app/index.cfm` | The reproduction. Options: `threads` (10), `classes` (10), `properties` (12), `mode` (`param`, `write`, `struct`), `trace`. |
| `app/build-info.cfm` | Which jar each class was loaded from, what backs component metadata, and whether our fix is installed. |
| `app/speed.cfm` | A rough single-threaded speed check, stock vs our fix. |
| `app/ping.cfm` | Answers `ok` once the server is up (used by `repro.ps1`). |
| `fix/PatchCaseInsensitiveMap.java` | Our withdrawn fix: the two default constructors, nothing else. Refuses to run if the class is not the expected shape. |
| `fix/build-fix.ps1` | Builds the withdrawn fix from a server's own engine jar and installs it. For the test servers only. |
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
