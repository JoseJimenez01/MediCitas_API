# Restaurant API — Servicio HTTP contenerizado con Docker Compose

Servicio REST de **reservas de mesa** en **ASP.NET Core 8** con persistencia en
**PostgreSQL**, autenticación delegada en **Keycloak** (JWT/OIDC, sin login propio) y
orquestación completa con **Docker Compose**.

El sistema completo se levanta con **un solo comando** y queda operativo sin pasos
manuales: el esquema se crea solo, el realm de Keycloak se importa solo y los healthchecks
ordenan el arranque.

```
┌────────────────────────  red Docker (Compose)  ────────────────────────┐
│                                                                        │
│   ┌──────────────┐   por nombre de servicio   ┌─────────────────────┐  │
│   │  api (app)   │ ◄────────────────────────► │  bd (PostgreSQL 16) │  │
│   │ :8080        │   bd:5432 (restaurantdb)   │ :5432  + volumen    │  │
│   └──────┬───────┘                            └─────────────────────┘  │
│          │ por nombre de servicio                                      │
│          │ auth:8080 (OIDC: validación de JWT)                         │
│          ▼                                                             │
│   ┌─────────────────────┐                                              │
│   │  auth (Keycloak 26) │  realm restaurant (importado al arrancar)    │
│   │ :8080 (host:8081)   │  client restaurant-api, rol api-writer       │
│   └─────────────────────┘                                              │
└────────────────────────────────────────────────────────────────────────┘
```

**Puertos publicados al host:** API en `http://localhost:8080`, Keycloak en
`http://localhost:8081`.

---

## 1. Requisitos previos

- **Docker** con el plugin **Docker Compose** (v2).
- Ningún otro requisito para el arranque: la imagen del servicio se construye desde el
  repositorio y las imágenes oficiales (`postgres`, `keycloak`) se descargan solas.
- Para **correr las pruebas** se necesita además el **.NET SDK 8** en la máquina
  (`dotnet test`), o bien ejecutarlas con el contenedor del SDK (sección 4).

---

## 2. Puesta en marcha (reproducible)

**Previo (una sola vez):**

```bash
cp .env.example .env     # y ajustar valores si se desea (los de ejemplo funcionan)
```

**Arrancar el sistema completo:**

```bash
docker compose up -d
```

Este único comando:

1. crea la red, el **volumen** de PostgreSQL (`postgres_data`) y los tres servicios;
2. inicia **PostgreSQL** y espera a que esté sano (`pg_isready`);
3. inicializa la base `keycloakdb` (script `db/init`) e inicia **Keycloak**, que importa
   el realm versionado `keycloak/realm-export.json` (`--import-realm`);
4. recién cuando sus dependencias están sanas, inicia la **API**, que crea la tabla
   `reservas` por código de arranque (con reintentos) y arranca escuchando en `:8080`.

**Verificar que el sistema quedó arriba y sano:**

```bash
docker compose ps          # los tres servicios en estado "healthy"
curl -s http://localhost:8080/health   # {"status":"healthy"} -> 200
curl -s http://localhost:8080/ready    # {"status":"ready"}    -> 200
```

> `/health` responde **sin tocar la base** (liveness). `/ready` comprueba la conexión a
> PostgreSQL (readiness): `200` si la base acepta consultas, `503` si no.

**Probar un ciclo completo sin token y con token** en el que la app misma valida la firma
contra Keycloak, en 6 comandos:

```bash
# 1. Sin token -> 401
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8080/reservas \
  -H "Content-Type: application/json" \
  -d '{"nombreCliente":"Ana","fecha":"2026-08-20","hora":"19:30:00","cantidadPersonas":4}'

# 2. Obtener token del usuario "escritor" (delegado a Keycloak)
TOKEN=$(curl -s -X POST http://localhost:8081/realms/restaurant/protocol/openid-connect/token \
  -d "grant_type=password" -d "client_id=restaurant-api" \
  -d "username=escritor" -d "password=escritor-pass" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")

# 3. Crear con token -> 201
curl -s -w "\n%{http_code}\n" -X POST http://localhost:8080/reservas \
  -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
  -d '{"nombreCliente":"Ana Rodriguez","fecha":"2026-08-20","hora":"19:30:00","cantidadPersonas":4}'

# 4. Listar -> 200 y refleja lo escrito
curl -s http://localhost:8080/reservas

# 5. Token del usuario "lector" (SIN el rol) -> 403
TOKEN2=$(curl -s -X POST http://localhost:8081/realms/restaurant/protocol/openid-connect/token \
  -d "grant_type=password" -d "client_id=restaurant-api" \
  -d "username=lector" -d "password=lector-pass" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")

curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8080/reservas \
  -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN2" \
  -d '{"nombreCliente":"X","fecha":"2026-08-20","hora":"19:30:00","cantidadPersonas":2}'
```

---

## 3. Contrato de rutas

### Salud y disponibilidad (siempre abiertas, sin token)

| Método | Ruta | Descripción | Respuesta |
|---|---|---|---|
| `GET` | `/health` | **Liveness**. No toca la base de datos. | `200` `{"status":"healthy"}` |
| `GET` | `/ready` | **Readiness**. Verifica la conexión a PostgreSQL. | `200` `{"status":"ready"}` o `503` |

### Reservas (recurso)

| Método | Ruta | Auth | Descripción | Respuestas |
|---|---|---|---|---|
| `GET` | `/reservas` | pública | Lista todo. Admite filtro `?fecha=YYYY-MM-DD` | `200` `[ ... ]` |
| `GET` | `/reservas/{id}` | pública | Consulta por identificador | `200` / `404` |
| `POST` | `/reservas` | **rol requerido** | Crea una reserva | `201` / `400` / `401` / `403` |
| `PUT` | `/reservas/{id}` | **rol requerido** | Actualiza una reserva | `200` / `400` / `404` / `401` / `403` |
| `DELETE` | `/reservas/{id}` | **rol requerido** | Elimina una reserva | `204` / `404` / `401` / `403` |

> **Decisión documentada:** las **lecturas** (`GET`) quedan **públicas** y solo las
> **escrituras** (`POST`/`PUT`/`DELETE`) exigen token con el rol requerido. La spec deja
> esta decisión a criterio del grupo; aquí se eligió exponer el listado y la consulta sin
> autenticación y proteger únicamente las modificaciones.

### Cuerpo de una reserva y validación

```json
{
  "nombreCliente": "Ana Rodriguez",
  "fecha": "2026-08-20",
  "hora": "19:30:00",
  "cantidadPersonas": 4
}
```

- `nombreCliente`: obligatorio, máx. 120 caracteres.
- `fecha`: obligatoria, formato `yyyy-MM-dd`.
- `hora`: obligatoria, formato `HH:mm:ss`.
- `cantidadPersonas`: obligatorio, entero entre 1 y 50.

Cuerpo inválido o incompleto → **`400`** (RFC 7807, con el detalle por campo). Un recurso
inexistente → **`404`**. Ninguna de estas situaciones tumba el proceso: el servicio se
mantiene operativo (`/health` sigue en `200`).

---

## 4. Pruebas (unitarias + integración)

Con la pila arriba (`docker compose up -d`), exportar la configuración y correr **todas**
las pruebas con un solo comando:

```bash
export TEST_API_BASE_URL=http://localhost:8080
export TEST_KEYCLOAK_TOKEN_URL=http://localhost:8081/realms/restaurant/protocol/openid-connect/token
export TEST_CLIENT_ID=restaurant-api
export TEST_CLIENT_SECRET=            # el client es público, no requiere secret
export TEST_USERNAME=escritor        TEST_PASSWORD=escritor-pass
export TEST_USERNAME_NOROLE=lector   TEST_PASSWORD_NOROLE=lector-pass

dotnet test Project_Restaurant_API.Tests/Project_Restaurant_API.Tests.csproj
```

Esperado: **28 passed** (20 unitarias + 8 integración).

**Solo unitarias** (sin Docker, PostgreSQL ni Keycloak):

```bash
dotnet test Project_Restaurant_API.Tests/Project_Restaurant_API.Tests.csproj \
  --filter "FullyQualifiedName~Unit"
```

Esperado: **20 passed** (validación de campos, límites 1–50 y mapeo DTO↔entidad).

**Sin .NET SDK local:** se pueden correr dentro del contenedor oficial del SDK,
apuntando a la pila levantada:

```bash
docker run --rm --network host -v "$PWD":/work -w /work \
  -e TEST_API_BASE_URL=http://localhost:8080 \
  -e TEST_KEYCLOAK_TOKEN_URL=http://localhost:8081/realms/restaurant/protocol/openid-connect/token \
  -e TEST_CLIENT_ID=restaurant-api \
  -mcr.microsoft.com/dotnet/sdk:8.0 \
  dotnet test Project_Restaurant_API.Tests/Project_Restaurant_API.Tests.csproj
```

**Variables de las pruebas** (valores por defecto entre paréntesis):

| Variable | Descripción |
|---|---|
| `TEST_API_BASE_URL` | URL de la API (`http://localhost:8080`) |
| `TEST_KEYCLOAK_TOKEN_URL` | Endpoint de token de Keycloak (puerto `8081`) |
| `TEST_CLIENT_ID` / `TEST_CLIENT_SECRET` | Client para pedir tokens (público → sin secret) |
| `TEST_USERNAME` / `TEST_PASSWORD` | Usuario **con** el rol (`escritor`) |
| `TEST_USERNAME_NOROLE` / `TEST_PASSWORD_NOROLE` | Usuario **sin** el rol (`lector`) |

Cobertura de las pruebas de integración (`Project_Restaurant_API.Tests/Integration`):

| Prueba | Qué verifica |
|---|---|
| `Health_Responde200_SinTocarLaBase` | liveness abierto |
| `Ready_Responde200_CuandoPostgresAceptaConsultas` | readiness contra la BD |
| `CicloCRUD_Completo_ConPersistencia` | 401 → 201 → listar → filtrar → 200 → PUT 200 → DELETE 204 → 404 |
| `Crear_CuerpoInvalido_Responde400` | validación de entrada |
| `Consultar_IdInexistente_Responde404` | recurso inexistente |
| `Escribir_SinToken_Responde401` | autenticación requerida |
| `Escribir_TokenSinRol_Responde403` | rol requerido |
| `Salud_Y_Disponibilidad_QuedanAbiertas_SinToken` | health/ready abiertas |

**Pruebas k6 end-to-end (Compose):** la pila incluye además un perfil opcional de pruebas
con **k6** que recorre el mismo contrato (401/403/400/201/200/filtro/404, PUT y DELETE)
y la persistencia, con comandos documentados:

```bash
./scripts/run-compose-integration.sh     # contrato completo con k6 en la red de Compose
./scripts/run-compose-persistence.sh     # escribe, reinicia, verifica y limpia (k6)
```

Requieren las variables `K6_*` en `.env` (ver sección 7).

---

## 5. Verificar la persistencia tras un reinicio

Los datos viven en el **volumen** `postgres_data`, no en la app:

```bash
# 1. Escribir un registro (con token)
curl -s -X POST http://localhost:8080/reservas \
  -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
  -d '{"nombreCliente":"Persistencia","fecha":"2026-12-24","hora":"13:00:00","cantidadPersonas":8}'

# 2. Bajar el sistema SIN borrar volúmenes
docker compose down

# 3. Volver a levantar
docker compose up -d

# 4. Leer los mismos datos (mismo id, misma fila)
curl -s "http://localhost:8080/reservas?fecha=2026-12-24"
```

> Usar `docker compose down` **sin** la bandera `-v`. Con `-v` se borra el volumen y los
> datos se pierden (útil para volver a un estado limpio, no para esta comprobación).

---

## 6. Apagar el sistema

```bash
docker compose down             # detiene y borra los contenedores, conserva el volumen
docker compose down -v          # idem, pero BORRA el volumen (pierde los datos)
docker compose down --rmi local # además elimina las imágenes locales construidas
```

---

## 7. Configuración (variables de entorno)

La imagen y el código **no contienen secretos**. Todo se inyecta por entorno usando
`.env.example` como plantilla; el `.env` real está en `.gitignore` y nunca se versiona.

| Variable | Descripción | Ejemplo |
|---|---|---|
| `API_PORT` / `KC_PORT` | Puertos publicados al host de la API y de Keycloak | `8080` / `8081` |
| `TAG_PG` | Tag de la imagen `postgres` | `16-alpine` |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | Credenciales y base de la app | `postgres` / `secretodesk` / `restaurantdb` |
| `TAG_KC` | Tag de la imagen de Keycloak | `26.0` |
| `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD` | Admin del realm `master` (solo bootstrap) | `admin` / `admin` |
| `KC_HEALTH_ENABLED` / `KC_METRICS_ENABLED` | Health/metrías de Keycloak (endpoint 9000) | `true` |
| `KC_DB` / `KC_DB_URL` | Motor y JDBC de Keycloak (su propia base) | `postgres` / `jdbc:postgresql://bd:5432/keycloakdb` |
| `KC_CACHE` / `KC_HTTP_ENABLED` / `KC_HOSTNAME_STRICT` | Dev local de Keycloak | `local` / `true` / `false` |
| `KEYCLOAK_REALM` | Realm importado | `restaurant` |
| `KEYCLOAK_AUTHORITY` | Issuer para descubrimiento OIDC, **por nombre de servicio** | `http://auth:8080/realms/restaurant` |
| `KEYCLOAK_VALID_ISSUER` | Issuer real que ponen los tokens emitidos por `localhost:KC_PORT` | `http://localhost:8081/realms/restaurant` |
| `KEYCLOAK_REQUIRED_ROLE` | Rol exigido para escribir | `api-writer` |
| `KEYCLOAK_AUDIENCE` | (opcional) Audiencia esperada del token | — |

La cadena de conexión de la app se arma a partir de `POSTGRES_*` en `Program.cs`
(`Host=bd`, `Port=5432`, `Database=...`, `Username=...`, `Password=...`).

---

## 8. Autenticación con Keycloak

- El servicio **no** implementa login ni firma de tokens; solo **valida** los JWT que
  recibe contra el proveedor (OIDC discovery + llaves públicas de Keycloak,
  `AddJwtBearer` + `options.Authority`).
- El realm `restaurant` está versionado en `keycloak/realm-export.json` y se importa al
  arrancar Keycloak (`command: start-dev --import-realm`). Contiene:
  - **client** `restaurant-api`: público con *Direct Access Grants* (permite el flujo
    `grant_type=password` de las pruebas y de la sección 2, sin secret).
  - **rol** de realm `api-writer`.
  - **usuarios** `escritor` / `escritor-pass` (con el rol) y `lector` / `lector-pass`
    (sin el rol, solo roles por defecto).
- `POST`/`PUT`/`DELETE` exigen la política `Escritura` (`RequireRole(KEYCLOAK_REQUIRED_ROLE)`).
- El rol llega en el claim `realm_access.roles`; `Auth/KeycloakClaimsTransformation.cs` lo
  extrae y lo expone como `ClaimTypes.Role` para que ASP.NET lo evalúe.
- Resultados: sin token o token inválido → **401**; token válido **sin** el rol → **403**;
  `secretodesk`-less y con el rol → operación permitida.

> **Por qué dos "issuers":** dentro de la red de Compose la app solo puede alcanzar a
> Keycloak por `http://auth:8080`, y así descubre las llaves públicas. Los tokens que
> emite el proveedor cuando un cliente humano lo contacta por `http://localhost:8081`
> llevan ese host en su `iss`. Como esa parte del `iss` depende de cómo se contacta al
> servicio, se fija explícitamente con `KEYCLOAK_VALID_ISSUER`. El código lo soporta
> (opcional en `.env`), y la validación de firma siempre se hace contra las llaves que
> publica `http://auth:8080/realms/restaurant`.

---

## 9. Inicialización automática del esquema

Al arrancar, la API ejecuta `Database.EnsureCreatedAsync()` (`Program.cs`) con reintentos
contra la base: si la tabla `reservas` no existe, la crea. **No hay que cargar esquemas a
mano.** La base `keycloakdb` (exclusiva del proveedor) la crea `db/init/01-keycloak-db.sql`
la primera vez que se inicializa el volumen de PostgreSQL; separar bases evita que el
esquema de Keycloak (decenas de tablas) haga que EF Core asuma que el de la app ya existe.

---

## 10. Decisiones de contenerización (`Dockerfile`)

| Decisión | Justificación |
|---|---|
| `FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build` | Imagen **base oficial** de Microsoft para .NET 8: contiene `dotnet restore`/`publish` para compilar el servicio y sus dependencias. |
| Etapa de ejecución `FROM mcr.microsoft.com/dotnet/aspnet:8.0` | **Multi-stage**: la imagen final lleva solo el runtime ASP.NET, sin SDK ni herramientas de compilación → más pequeña y con menor superficie de ataque. |
| `COPY . .` + `.dockerignore` | El contexto copia únicamente el código; el `.dockerignore` excluye de la imagen lo que no corresponde: historial `.git`, dependencias del entorno de desarrollo (`bin/`, `obj/`), secretos (`.env*`), el `Dockerfile`/compose, el README y `docs/`. |
| `EXPOSE 8080` | Declara el puerto: las imágenes aspnet de .NET 8 escuchan en `8080` (`ASPNETCORE_HTTP_PORTS=8080`); el compose lo publica en el host. |
| `ENTRYPOINT ["dotnet", "Project_Restaurant_API.dll"]` | Comando de arranque del proceso publicado. |
| Sin secretos | No hay contraseñas ni en el `Dockerfile` ni en archivos copiados: todas las credenciales llegan por variables de entorno. |

## 11. Decisiones de orquestación (`docker-compose.yml`)

| Decisión | Justificación |
|---|---|
| Red por **nombre de servicio** (`bd`, `auth`) | La app alcanza la base y el proveedor por nombre de servicio en la red que crea Compose, nunca por IP fija ni `localhost`. |
| Volumen `postgres_data` | Los datos de PostgreSQL residen en un volumen declarado que sobrevive a `down`/`up` (persistencia verificada en la sección 5). |
| `healthcheck` en los tres servicios | `bd` usa `pg_isready`; `auth` consulta `/health/ready` (9000); la app consulta `/health`. Así Compose sabe cuándo cada servicio está sano. |
| `depends_on: condition: service_healthy` | La app **no se da por lista** hasta que PostgreSQL y Keycloak están sanos; Keycloak, hasta que la base lo está. Estrategia elegida: `depends_on` con condición de healthcheck (más `EnsureCreatedAsync` con reintentos dentro de la app como segunda red de seguridad). |
| `--import-realm` + `keycloak/realm-export.json` | El realm se importa solo al arrancar: **cero pasos manuales** en la consola de Keycloak, clave para la reproducibilidad. |
| `db/init/01-keycloak-db.sql` | Crea la base propia del proveedor la primera vez que se inicializa el volumen (los scripts de `docker-entrypoint-initdb.d` solo corren al inicializar). |
| Configuración por entorno (`${VAR}`) | Todo valor sensible o de configuración sale de `.env` (con plantilla `.env.example`). |
| `container_name` | Nombres fijos para simplificar los healthchecks y la depuración (opcional; no afecta la resolución por nombre de servicio). |

---

## 12. Kubernetes y Kustomize (grupos de tres)

El mismo sistema se despliega sobre un clúster local **kind** con manifiestos en
`k8s/` (carpeta `base/` + overlay `local/`), con Kustomize. Cada concepto de Compose tiene
su correspondiente en Kubernetes:

| Compose | Kubernetes |
|---|---|
| servicio `api` (imagen propia) | `Deployment restaurant-api` + `Service` (ClusterIP) |
| servicio `bd` (PostgreSQL) | `Deployment postgres` + `Service` + `PVC postgres-data` |
| servicio `auth` (Keycloak) | `Deployment keycloak` + `Service` (ClusterIP) |
| volumen `postgres_data` | `PersistentVolumeClaim` `postgres-data` |
| healthchecks + `depends_on` | `startupProbe` / `livenessProbe` (/health) / `readinessProbe` (/ready) + `initContainers` que esperan a las dependencias |
| variables de entorno (`.env`) | `ConfigMap restaurant-config` + `Secret restaurant-secrets` (secretGenerator del overlay) |
| realm importado (`--import-realm`) | `initContainer` que renderiza el realm desde una plantilla (`k8s/base/keycloak/realm-template.json`) e importa con `--import-realm` |

**Requisitos:** Docker, `kind` y `kubectl` en el PATH.

**Comandos reproducibles** (se ejecutan desde la raíz del repositorio):

```bash
./scripts/k8s-up.sh                    # crea el clúster kind, carga la imagen, aplica el
                                       # overlay y verifica que los Deployments queden listos
# API desde el host: http://localhost:8081 (NodePort 30081 -> :8081)

./scripts/k8s-run-integration.sh       # ejecuta el contrato completo con k6 (Job en el clúster)
./scripts/k8s-run-persistence.sh       # escribe con k6, borra el Pod postgres, verifica que el
                                       # dato sobrevive (PVC) y limpia
./scripts/k8s-down.sh                  # elimina el clúster kind
```

La primera vez que se aplica el overlay, `k8s-up.sh` crea `k8s/overlays/local/secrets.env`
desde la plantilla `secrets.env.example` (valores de desarrollo válidos; este archivo no se
versiona). La imagen se construye con el mismo `Dockerfile` del repo y se carga en kind:

```bash
docker build -t restaurant-api:local .   # equivalente a lo que hace k8s-up.sh
```

## 13. Estructura del repositorio

```
.
├── Dockerfile
├── docker-compose.yml
├── .env.example               # plantilla de configuración (versionada)
├── .dockerignore              # excluye de la imagen lo que no corresponde
├── .gitignore                 # .env, bin/obj, etc. fuera del repositorio
├── db/init/01-keycloak-db.sql # base exclusiva de Keycloak (1er arranque del volumen)
├── keycloak/realm-export.json # realm de Keycloak importado al arrancar
├── k8s/                       # manifiestos Kubernetes (módulo de grupo de tres)
│   ├── base/                  # base de Kustomize (Deployments, Services, PVC, ConfigMap…)
│   └── overlays/local/        # overlay local: kind-config, NodePort, Secret via Kustomize
├── scripts/                   # k8s-up/down, k8s-run-* y run-compose-* (integración k6)
├── tests/k6/                  # pruebas k6: contrato completo y persistencia
├── INTEGRATION_CONTRACT.md    # contrato de integración coordinado entre partes
├── README.md
├── Project_Restaurant_API/                    # servicio ASP.NET Core 8
│   ├── Program.cs                             # config, auth JWT, /health, /ready, esquema
│   ├── Controllers/ReservasController.cs      # CRUD del recurso
│   ├── Data/RestaurantContext.cs              # EF Core + Npgsql (tabla "reservas")
│   ├── Models/Reserva.cs                      # entidad del dominio
│   ├── Dtos/ReservaInputDto.cs / ReservaDto.cs
│   └── Auth/KeycloakClaimsTransformation.cs   # roles de Keycloak → ClaimTypes.Role
└── Project_Restaurant_API.Tests/              # 20 unitarias + 8 de integración
```

## 14. Declaración de uso de IA

##### [Josimar Araya]()

- k6 – Pruebas de integración: Para facilitar la estructuración y revisión de los scripts de pruebas automatizadas sobre los endpoints ya definidos por el proyecto

- k6 – Autenticación y persistencia: Apoyo en validación de escenarios con tokens de Keycloak, respuestas 401/403 y comprobaciones de persistencia desde las pruebas

- Kubernetes – Manifiestos: Parcialmente para generar y revisar general de los Deployments, Services, PVC, ConfigMap, Secret y probes necesarios para desplegar el sistema

- Kustomize y kind: Se utilizó para estructurar base/ y overlays/, configurar el clúster local con kind y revisar los comandos de despliegue

- Además se usó en general para revisar y validar algunos códigos y flujo de proceso además de arreglar errores, fallas generales y problemas de código

##### [Franco Rojas]()

-

-

-

##### [José Jiménez](https://github.com/JoseJimenez01)

- Refrescar términos, explicación del funcionamiento de algunas cosas(tecnologías, conexión entre componentes, etc).

- Solución de errores.

- Consultar la documentación rápidamente en busca de buenas prácticas de uso de cierta tecnología.

- Si fuera el caso, para generar data de una BD, o generar los tests de prueba.



