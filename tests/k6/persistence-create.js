import http from 'k6/http';
import { check, fail, sleep } from 'k6';

const API_URL = __ENV.API_URL || 'http://api:8080';
const KEYCLOAK_URL = __ENV.KEYCLOAK_URL || 'http://auth:8080';
const REALM = __ENV.KEYCLOAK_REALM || 'restaurant';
const CLIENT_ID = __ENV.KEYCLOAK_CLIENT_ID || 'restaurant-api';
const CLIENT_SECRET = __ENV.KEYCLOAK_CLIENT_SECRET || '';
const USERNAME = __ENV.K6_WRITER_USERNAME || 'k6_writer';
const PASSWORD = __ENV.K6_WRITER_PASSWORD || '';
const RESOURCE_PATH = __ENV.RESOURCE_PATH || '/reservas';
const MARKER = __ENV.PERSISTENCE_MARKER;
const DATE = __ENV.PERSISTENCE_DATE;

export const options = {
    vus: 1,
    iterations: 1,
    thresholds: {
        checks: ['rate==1'],
        http_req_failed: ['rate==0'],
    },
};

function token() {
    const data = {
        grant_type: 'password',
        client_id: CLIENT_ID,
        username: USERNAME,
        password: PASSWORD,
    };
    if (CLIENT_SECRET !== '') data.client_secret = CLIENT_SECRET;

    // Keycloak comparte el postgres que se acaba de reiniciar: sus primeros
    // intentos pueden devolver 5xx mientras rehabilita el pool. Reintento acotado
    // con backoff (3, 6, 9, ... 24s) para no tumbar la creacion de persistencia.
    const maxIntentos = 8;
    let r = null;
    for (let intento = 1; intento <= maxIntentos; intento++) {
        r = http.post(
            `${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token`,
            data,
            { responseCallback: http.expectedStatuses(200), tags: { name: 'keycloak-token-writer' } }
        );

        if (r.status === 200) break;

        if (intento < maxIntentos) {
            console.log(`Token pendiente (${r.status}); reintento ${intento}/${maxIntentos - 1}...`);
            sleep(3 * intento);
        }
    }

    if (!check(r, { 'Keycloak entrega token writer': (x) => x.status === 200 })) {
        fail(`No se pudo obtener token: ${r.status} ${r.body}`);
    }
    return r.json('access_token');
}

export default function () {
    if (!MARKER || !DATE || !PASSWORD) {
        fail('Faltan PERSISTENCE_MARKER, PERSISTENCE_DATE o K6_WRITER_PASSWORD.');
    }

    const accessToken = token();
    const body = JSON.stringify({
        nombreCliente: MARKER,
        fecha: DATE,
        hora: '12:00:00',
        cantidadPersonas: 3,
    });

    const response = http.post(`${API_URL}${RESOURCE_PATH}`, body, {
        headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${accessToken}`,
        },
        responseCallback: http.expectedStatuses(201),
        tags: { name: 'persistencia-crear' },
    });

    check(response, {
        'Persistencia: POST responde 201': (r) => r.status === 201,
        'Persistencia: recurso contiene marcador': (r) => r.body.includes(MARKER),
    });
}
