import http from 'k6/http';
import { check, fail, group } from 'k6';

const API_URL = __ENV.API_URL || 'http://api:8080';
const KEYCLOAK_URL = __ENV.KEYCLOAK_URL || 'http://auth:8080';
const KEYCLOAK_REALM = __ENV.KEYCLOAK_REALM || 'restaurant';
const KEYCLOAK_CLIENT_ID = __ENV.KEYCLOAK_CLIENT_ID || 'restaurant-api';
const KEYCLOAK_CLIENT_SECRET = __ENV.KEYCLOAK_CLIENT_SECRET || '';

const WRITER_USERNAME = __ENV.K6_WRITER_USERNAME || 'k6_writer';
const WRITER_PASSWORD = __ENV.K6_WRITER_PASSWORD || '';
const READER_USERNAME = __ENV.K6_READER_USERNAME || 'k6_reader';
const READER_PASSWORD = __ENV.K6_READER_PASSWORD || '';

const RESOURCE_PATH = __ENV.RESOURCE_PATH || '/reservas';
const TEST_MARKER = __ENV.TEST_MARKER || `K6-${Date.now()}`;

function futureDate(days) {
    const date = new Date();
    date.setUTCDate(date.getUTCDate() + days);
    return date.toISOString().slice(0, 10);
}

const TEST_DATE = __ENV.TEST_DATE || futureDate(7);

export const options = {
    vus: 1,
    iterations: 1,
    thresholds: {
        checks: ['rate==1'],
        http_req_failed: ['rate==0'],
    },
};

function requestParams(token, expectedStatus, name) {
    const headers = { 'Content-Type': 'application/json' };

    if (token) {
        headers.Authorization = `Bearer ${token}`;
    }

    return {
        headers,
        tags: { name },
        responseCallback: http.expectedStatuses(expectedStatus),
    };
}

function safeJson(response) {
    try {
        return response.json();
    } catch (_) {
        return null;
    }
}

function getToken(username, password, tag) {
    const tokenUrl = `${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token`;
    const body = {
        grant_type: 'password',
        client_id: KEYCLOAK_CLIENT_ID,
        username,
        password,
    };

    if (KEYCLOAK_CLIENT_SECRET !== '') {
        body.client_secret = KEYCLOAK_CLIENT_SECRET;
    }

    const response = http.post(tokenUrl, body, {
        tags: { name: `keycloak-token-${tag}` },
        responseCallback: http.expectedStatuses(200),
    });

    const ok = check(response, {
        [`Keycloak entrega token (${tag})`]: (r) => r.status === 200,
        [`Token ${tag} contiene access_token`]: (r) => {
            const json = safeJson(r);
            return json !== null && typeof json.access_token === 'string';
        },
    });

    if (!ok) {
        console.log(`Respuesta Keycloak (${tag}): ${response.status} ${response.body}`);
        fail(`No se pudo obtener el token ${tag}`);
    }

    return response.json('access_token');
}

function bodyContainsId(response, id) {
    const json = safeJson(response);
    return json !== null && String(json.id) === String(id);
}

export function setup() {
    if (WRITER_PASSWORD === '' || READER_PASSWORD === '') {
        fail('Faltan K6_WRITER_PASSWORD y/o K6_READER_PASSWORD en el entorno.');
    }

    return {
        writerToken: getToken(WRITER_USERNAME, WRITER_PASSWORD, 'writer'),
        readerToken: getToken(READER_USERNAME, READER_PASSWORD, 'reader'),
    };
}

export default function (data) {
    let response;
    let id;

    group('Salud y disponibilidad', () => {
        response = http.get(
            `${API_URL}/health`,
            requestParams(null, 200, 'GET /health')
        );

        check(response, {
            'GET /health responde 200': (r) => r.status === 200,
            'GET /health devuelve JSON': (r) =>
                (r.headers['Content-Type'] || '').includes('application/json'),
        });

        response = http.get(
            `${API_URL}/ready`,
            requestParams(null, 200, 'GET /ready')
        );

        check(response, {
            'GET /ready responde 200': (r) => r.status === 200,
            'GET /ready devuelve JSON': (r) =>
                (r.headers['Content-Type'] || '').includes('application/json'),
        });
    });

    const reservation = {
        nombreCliente: TEST_MARKER,
        fecha: TEST_DATE,
        hora: '19:30:00',
        cantidadPersonas: 2,
    };

    const updatedReservation = {
        nombreCliente: `${TEST_MARKER}-actualizada`,
        fecha: TEST_DATE,
        hora: '20:00:00',
        cantidadPersonas: 4,
    };

    const invalidReservation = {
        nombreCliente: '',
        fecha: '',
        hora: '',
        cantidadPersonas: 0,
    };

    group('Creacion y validacion', () => {
        response = http.post(
            `${API_URL}${RESOURCE_PATH}`,
            JSON.stringify(reservation),
            requestParams(null, 401, 'POST sin token')
        );
        check(response, {
            'POST sin token responde 401': (r) => r.status === 401,
        });

        response = http.post(
            `${API_URL}${RESOURCE_PATH}`,
            JSON.stringify(reservation),
            requestParams(data.readerToken, 403, 'POST sin rol')
        );
        check(response, {
            'POST con token sin rol responde 403': (r) => r.status === 403,
        });

        response = http.post(
            `${API_URL}${RESOURCE_PATH}`,
            JSON.stringify(invalidReservation),
            requestParams(data.writerToken, 400, 'POST invalido')
        );
        check(response, {
            'POST invalido responde 400': (r) => r.status === 400,
        });

        response = http.post(
            `${API_URL}${RESOURCE_PATH}`,
            JSON.stringify(reservation),
            requestParams(data.writerToken, 201, 'POST valido')
        );

        const json = safeJson(response);
        const created = check(response, {
            'POST autorizado responde 201': (r) => r.status === 201,
            'POST devuelve el recurso creado': () => json !== null,
            'POST devuelve un identificador': () =>
                json !== null && json.id !== undefined && json.id !== null,
        });

        if (!created) {
            console.log(`Respuesta POST: ${response.status} ${response.body}`);
            fail('No se pudo crear el recurso; no es posible continuar el CRUD.');
        }

        id = json.id;
    });

    group('Lectura y filtro', () => {
        response = http.get(
            `${API_URL}${RESOURCE_PATH}`,
            requestParams(null, 200, 'GET lista')
        );

        check(response, {
            'GET lista responde 200': (r) => r.status === 200,
            'GET lista devuelve un arreglo': (r) => Array.isArray(safeJson(r)),
            'GET lista contiene el recurso creado': (r) => r.body.includes(TEST_MARKER),
        });

        response = http.get(
            `${API_URL}${RESOURCE_PATH}?fecha=${encodeURIComponent(TEST_DATE)}`,
            requestParams(null, 200, 'GET filtro')
        );

        check(response, {
            'GET con filtro responde 200': (r) => r.status === 200,
            'GET con filtro contiene el recurso creado': (r) => r.body.includes(TEST_MARKER),
            'GET con filtro solo devuelve la fecha solicitada': (r) => {
                const items = safeJson(r);
                return Array.isArray(items) && items.every((item) => item.fecha === TEST_DATE);
            },
        });

        response = http.get(
            `${API_URL}${RESOURCE_PATH}/${id}`,
            requestParams(null, 200, 'GET por id')
        );

        check(response, {
            'GET por id responde 200': (r) => r.status === 200,
            'GET por id devuelve el mismo id': (r) => bodyContainsId(r, id),
        });

        response = http.get(
            `${API_URL}${RESOURCE_PATH}/2147483647`,
            requestParams(null, 404, 'GET inexistente')
        );

        check(response, {
            'GET inexistente responde 404': (r) => r.status === 404,
        });
    });

    group('Actualizacion protegida', () => {
        response = http.put(
            `${API_URL}${RESOURCE_PATH}/${id}`,
            JSON.stringify(updatedReservation),
            requestParams(null, 401, 'PUT sin token')
        );
        check(response, {
            'PUT sin token responde 401': (r) => r.status === 401,
        });

        response = http.put(
            `${API_URL}${RESOURCE_PATH}/${id}`,
            JSON.stringify(updatedReservation),
            requestParams(data.readerToken, 403, 'PUT sin rol')
        );
        check(response, {
            'PUT con token sin rol responde 403': (r) => r.status === 403,
        });

        response = http.put(
            `${API_URL}${RESOURCE_PATH}/${id}`,
            JSON.stringify(invalidReservation),
            requestParams(data.writerToken, 400, 'PUT invalido')
        );
        check(response, {
            'PUT invalido responde 400': (r) => r.status === 400,
        });

        response = http.put(
            `${API_URL}${RESOURCE_PATH}/2147483647`,
            JSON.stringify(updatedReservation),
            requestParams(data.writerToken, 404, 'PUT inexistente')
        );
        check(response, {
            'PUT inexistente responde 404': (r) => r.status === 404,
        });

        response = http.put(
            `${API_URL}${RESOURCE_PATH}/${id}`,
            JSON.stringify(updatedReservation),
            requestParams(data.writerToken, 200, 'PUT valido')
        );

        check(response, {
            'PUT autorizado responde 200': (r) => r.status === 200,
            'PUT devuelve el mismo id': (r) => bodyContainsId(r, id),
            'PUT devuelve la version actualizada': (r) =>
                r.body.includes(`${TEST_MARKER}-actualizada`),
        });
    });

    group('Eliminacion protegida', () => {
        response = http.del(
            `${API_URL}${RESOURCE_PATH}/${id}`,
            null,
            requestParams(null, 401, 'DELETE sin token')
        );
        check(response, {
            'DELETE sin token responde 401': (r) => r.status === 401,
        });

        response = http.del(
            `${API_URL}${RESOURCE_PATH}/${id}`,
            null,
            requestParams(data.readerToken, 403, 'DELETE sin rol')
        );
        check(response, {
            'DELETE con token sin rol responde 403': (r) => r.status === 403,
        });

        response = http.del(
            `${API_URL}${RESOURCE_PATH}/${id}`,
            null,
            requestParams(data.writerToken, 204, 'DELETE valido')
        );
        check(response, {
            'DELETE autorizado responde 204': (r) => r.status === 204,
            'DELETE 204 no devuelve cuerpo': (r) => r.body === null || r.body === '',
        });

        response = http.get(
            `${API_URL}${RESOURCE_PATH}/${id}`,
            requestParams(null, 404, 'GET despues de DELETE')
        );
        check(response, {
            'GET despues de DELETE responde 404': (r) => r.status === 404,
        });

        response = http.del(
            `${API_URL}${RESOURCE_PATH}/${id}`,
            null,
            requestParams(data.writerToken, 404, 'DELETE inexistente')
        );
        check(response, {
            'DELETE inexistente responde 404': (r) => r.status === 404,
        });
    });
}
