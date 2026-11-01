# Plan-Revision 2 — Änderungsprotokoll

**Datum:** 2026-10-22 · **Anlass:** Neue Zielarchitektur (Mehrprozess-Server-Container, Plugins als Prozesse im Server-Container, Infrastruktur zuerst, danach Instagram-Plugin in eigenem Repo).
*Dieses Dokument ist ein Arbeitsprotokoll für den Maintainer (deutsch); die eigentlichen Planungsdokumente sind englisch.*

## 1. Die Kernänderungen in einem Satz pro Thema

| Thema | Vorher (Rev. 1) | Jetzt (Rev. 2) |
| --- | --- | --- |
| Server | Core, Gateway, Watchdog = Module in **einem** Prozess (ADR-0001) bzw. widersprüchlich (ADR-0003) | **Mehrere Prozesse** im Server-Container, jeder mit eigener UID; Kommunikation per gRPC über Unix-Sockets |
| Watchdog | beobachtet nur, kein Restart, „kein Custom-Supervisor" | **PID 1 + Supervisor** (Start, Restart mit Backoff, Crash-Loop, Health, Secret-Verteilung) – aber ohne Docker-Zugriff |
| Plugins | eigene, eingeschränkte Container | **Native Executables als Kindprozesse im Server-Container**, eine UID pro Plugin |
| Vertrauensmodell | implizit „Dritt-Plugins möglich" | **Nur bundled/operator-approved**; untrusted Code in v1 ausdrücklich nicht unterstützt |
| Plugin-Daten | Schema pro Plugin + Plugin-Migrationen | **JSONB-Key/Value-Tabelle in Core**, kein DDL/SQL für Plugins |
| Plugin-UI | iframe + postMessage-Bridge | **Deklarative Descriptor** (JSON-Schema-Subset), vom Frontend gerendert |
| Credentials | `secrets.use` ohne Herausgabe | Core speichert verschlüsselt, Plugin **leased** Klartext pro Aufruf (auditiert) |
| User-Kontext | unklar | **Call Tokens**: Plugin handelt nur innerhalb Core-initiierter Aufrufe |
| Web↔Server | „IPC" | gRPC über TCP mit **mTLS** (Zertifikate per Skript) |
| Roadmap | 17 Milestones, Instagram erst M12 | **Phase A** (M0–M13: Infrastruktur, per Demo-Plugin verifiziert) → **Phase B** (P0–P4: Instagram) |
| Instagram-Risiko | Prüfung erst vor Instagram-Milestone | **M0.5** (Doku-only, parallel) – vor dem Contract-Freeze |

## 2. Änderungen pro Datei

| Datei | Status | Was genau |
|--- | --- | --- |
| `README.md` | angepasst | Dein persönlicher Text bleibt. Neu: Projektbeschreibung, Architektur-Skizze, Doku-Tabelle, Repo-Liste, Status, Quick-Start. Nur Tippfehler korrigiert („discored", „planing", „Ai", „a idea") |
| `docker-compose.yaml` | **neu** (war Platzhalter) | Skeleton: Netzwerke `public` / `backend` (internal) / `egress`; Secrets als Dateien; gehärtete Container; Healthchecks; optionales `proxy`-Profil. Marker „M1.2" = beim ersten echten Image zu verifizieren/pinnen |
| `.env.example` | **neu** (war Platzhalter) | Nur Nicht-Secret-Konfiguration; Defaults bewusst sicher (Bind auf `127.0.0.1`) |
| `.gitignore` | angepasst | zusätzlich `.env`, `secrets/*` (außer `.gitkeep`) |
| `Caddyfile.example` | neu | Minimale TLS-Reverse-Proxy-Konfiguration für das `tls`-Profil |
| `scripts/init-secrets.sh` | neu | Erzeugt DB-Passwort, Master-Key, interne CA + Server-/Web-Zertifikate; überschreibt nichts ohne `--force` |
| `docs/decisions/ADR-0001` | **neu geschrieben** | Systemgrenzen für das Mehrprozess-Modell; Tabelle „Rev. 1 → Rev. 2" |
| `docs/decisions/ADR-0002` | angepasst | BFF um generische OAuth-Callback- und öffentliche Medien-Route, mTLS, TLS-Profil und Descriptor-Rendering erweitert |
| `docs/decisions/ADR-0003` | überarbeitet | C++ bleibt, aber mit **Validierungs-Gate (M0.2)**; Bibliotheks-Vorschläge; Repo-Liste inkl. SDK; Verträge liegen in `proto/` dieses Repos (Entscheidung des Maintainers, siehe Nachtrag). Der Widerspruch zu ADR-0001 ist aufgelöst |
| `proto/` | **neu** (Nachtrag) | Entwurfsdateien für `common`, `plugin`, `host`, `watchdog` (identisch mit den kompilierten Skizzen aus `IPC_PROTOCOL.md`) plus `README.md` mit Regeln |
| `docs/decisions/ADR-0004` | **neu** | Prozessmodell, Watchdog als PID 1 (Rechte, Control-API), Secret-Verteilung, Plugin-Hosting, Trust-Modell, Netzwerk |
| `docs/decisions/ADR-0005` | **neu** | Call Tokens, KV-Storage, Credential-Lease, deklarative UI, Publishing-Vertrag (Outcome-Klassen, Checkpoint, Reconcile) |
| `docs/decisions/OPEN_DECISIONS.md` | neu geschrieben | Kaputte Tabelle repariert; 21 Einträge (OD-04/05/06/08 geschlossen, OD-13…21 neu); Default und Zeitpunkt je Entscheidung |
| `docs/architecture/ARCHITECTURE.md` | neu geschrieben | Topologie, Prozess-/Socket-Layout, Kommunikations- und Verbotspfade, Verantwortlichkeiten, vier Kernabläufe, Datenmodell, Medien, Dateisystem |
| `docs/protocol/IPC_PROTOCOL.md` | neu geschrieben | Transporte, Identitätskette, Gateway-Regeln, **kompilierte Proto-Skizzen** (Plugin-, Host-, Watchdog-Service), Fehler-Mapping, Idempotenz, Health-Sockets |
| `docs/plugins/PLUGIN_SPEC.md` | neu geschrieben | Paket/Manifest, Capabilities, Plugin- und Host-API, deklarative UI, Isolation, Trust-Stufen (aus `docs_old` übernommen und vereinfacht), Lifecycle, SDK |
| `docs/product/PRD.md` | neu geschrieben | Zwei Releases (Infra v0.1, Instagram v0.2), Rollen inkl. Operator, Scope/Non-Goals, Erfolgskriterien |
| `docs/product/FEATURE_LIST.md` | neu geschrieben | Prioritäten **plus** Release-Tags `[INFRA]` / `[IG]` / `[LATER]` und Milestone-Verweis je Feature |
| `docs/quality/NFR.md` | angepasst | Prozess-Fehlerisolation, Restart-/Shutdown-Werte, Ressourcenrahmen, Log-Redaction by construction, Backup-Scope inkl. Key-Trennung |
| `docs/security/THREAT_MODEL.md` | neu bewertet | T2 (In-Container-Plugins) neu; T3 für v1 „n/a"; **neu T13–T19** (Gateway, Watchdog, Secret-Zugriff, Lease, Public-Media, OAuth-Callback, Descriptor-Injection); Testliste |
| `docs/development/ROADMAP.md` | **neu geschrieben** | Phase A (M0–M13), Phase B (P0–P4), Gates, Risikoregister, Scope-Hebel, Demo-Skript |
| `docs/development/PLAN_REVISION_2.md` | neu | dieses Dokument |

Nicht angefasst: `docs_old/` (liegt lokal, ist per `.gitignore` ausgeschlossen – nicht im Repo; die brauchbaren Teile, v. a. die Trust-Levels, sind in `PLUGIN_SPEC` §11 eingeflossen).

## 3. Entscheidungen, die ich über deine Vorgaben hinaus getroffen habe (bitte bestätigen oder korrigieren)

1. **C++ bleibt** – aber mit hartem Gate in M0.2. Besteht der Spike nicht, wird per ADR neu entschieden (Verträge bleiben, da sprachneutral).
2. **Installation von Plugins per Operator-CLI**, nicht per Upload im Web-UI. Das UI verwaltet Enable/Disable, Berechtigungen, Konfiguration und Health. Grund: UI-Upload = Remote-Code-Execution-Pfad, der erst mit Signaturen sinnvoll ist.
3. **Plugin = ausführbares Programm**, kein `dlopen`-Code. Es muss im Server-Image lauffähig sein (statisch gelinkt oder gegen das gepinnte Basis-Image gebaut).
4. **Watchdog läuft als root mit minimalen Capabilities** und droppt für jeden Kindprozess. Das ist unvermeidbar für UID-Trennung und bewusst als Angriffsfläche dokumentiert (T14).
5. ~~Eigenes Repo `postflowx-proto`~~ → **vom Maintainer geändert:** die Verträge liegen im Ordner `proto/` des Deploy-Repos (siehe Nachtrag). Später kommt noch `postflowx-plugin-sdk` als eigenes Repo dazu.
6. **Egress-Netzwerk nur am Server**, weil Plugins Provider-APIs aufrufen; `backend` bleibt ohne Internet.
7. **Standard-Bind auf `127.0.0.1`**; für alles darüber hinaus TLS (Caddy-Profil oder eigener Proxy).
8. **Vorschläge für Session, Kryptografie, Zeit/DST, Admin-Bootstrap** (OD-03/07/09/20) sind als „Proposed" eingetragen und werden in M0.4 festgezurrt.
9. **Instagram-Machbarkeit (M0.5)** läuft parallel, obwohl die Infrastruktur Vorrang hat – kostet kaum Zeit und kann Anforderungen an die Infrastruktur ändern (HTTPS, öffentliche Medien-URLs).

## 4. Korrekturen an meinen früheren Aussagen

- Ich hatte `docs_old/` als „im Repo liegend" bezeichnet. Es ist per `.gitignore` ausgeschlossen und nur lokal vorhanden – kein Problem.
- Meine Kritik am „Gateway als Modul" und am „Watchdog ohne Restart" ist mit deinem neuen Modell gegenstandslos; die Docs sind dazu umgestellt, nicht mein früherer Rat.

## 5. Was verifiziert wurde – und was nicht

**Geprüft (automatisiert):**

- `docker-compose.yaml` ist valides YAML; jedes Secret wird referenziert und ist definiert.
- `scripts/init-secrets.sh`: Zertifikatskette verifiziert (`openssl verify`), SAN `server`, Key-Usage Server/Client korrekt, Überschreibschutz und `--force` funktionieren.
- Alle vier Proto-Skizzen aus `IPC_PROTOCOL.md` **kompilieren mit `protoc`**.
- Querverweise: Alle verwendeten OD-, T-, M- und P-Nummern sind definiert; alle relativen Links existieren; keine veralteten Begriffe außerhalb von Änderungstabellen/Negationen.

**Nicht geprüft (kein Docker in meiner Umgebung) – daher als „M1.2" markiert:**

- `docker compose up` selbst; Verhalten von Secret-Datei-Rechten (Rootful vs. Rootless), `DAC_READ_SEARCH`-Annahme und der Postgres-18-Volume-Pfad (`/var/lib/postgresql`).
- Alle Aussagen zu gRPC-C++-Fähigkeiten (generisches Proxying, Peer-Credentials auf UDS) sind Hypothesen für M0.2.
- Meta/Instagram-Details: bewusst **nicht** festgeschrieben, sondern an M0.5/P0 delegiert.

## 6. Offen und braucht dich

- **Lizenz (OD-18):** Du bittest in der README um Mithilfe – ohne `LICENSE` ist Mitarbeit rechtlich unklar.
- **Plugin-Sprache für Instagram (OD-14):** Default C++ mit dem SDK; Entscheidung bei P0.
- **Eigene Zeitbudgetierung:** Phase A ist realistisch mehrere Monate Vollzeit-ähnlicher Arbeit. Die „Scope-Hebel" in der Roadmap zeigen, was du streichen kannst, ohne das Demo-Skript zu verlieren.

## 7. Empfohlene nächste Schritte

1. Diese Dateien ins Repo übernehmen (alte ersetzen), `PLAN_REVISION_2.md` mitcommitten, ein Commit „docs: revision 2".
2. **M0.2-Spike** starten (zuerst Punkte 1, 2, 5, 6) – er entscheidet über C++ und die Tragfähigkeit der Isolation.
3. Parallel **M0.5** (Instagram-Machbarkeit) als reine Recherche.

## 8. Nachtrag: Verträge im Deploy-Repo statt eigenem Proto-Repo

**Entscheidung des Maintainers:** Es gibt kein eigenes `postflowx-proto`-Repo. Alle `.proto`-Dateien liegen im Ordner `proto/` dieses Repos.

**Geänderte Dateien:** `README.md`, ADR-0002, ADR-0003, `OPEN_DECISIONS.md` (OD-16), `ROADMAP.md` (Prinzip 4, M0.3, M1.1), `PLUGIN_SPEC.md`, `IPC_PROTOCOL.md`, `NFR.md`; neu: `proto/` mit den vier Entwurfsdateien und `proto/README.md`.

**Konsequenzen (bewusst festgehalten):**

- Vorteil: ein Repo weniger; Vertragsversion = Deploy-Repo-Tag = Release-Bundle – Verträge und Komponentenversionen können nicht auseinanderlaufen.
- Die Repos `postflowx-server`, `postflowx-web`, SDK und Instagram-Plugin holen sich nur `proto/` in einer festen Version (Tag/Commit) per Sparse-Checkout, Submodule oder Sync-Skript. Welche Variante, wird in M1.1 entschieden (OD-16). Generierter Code wird nicht eingecheckt.
- Das Plugin-Repo hängt für die Verträge vom Deploy-Repo ab. Das ist unkritisch, solange per Tag/Commit gepinnt wird.
- `buf breaking` läuft in der CI dieses Repos gegen den vorherigen Release-Tag.
- Quelle der Wahrheit: bis M0.3 sind die Skizzen in `IPC_PROTOCOL.md` und `proto/` deckungsgleich; ab M0.3 gilt `proto/`.
