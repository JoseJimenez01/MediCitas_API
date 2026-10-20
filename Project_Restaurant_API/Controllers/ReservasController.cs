using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Project_Restaurant_API.Data;
using Project_Restaurant_API.Dtos;

namespace Project_Restaurant_API.Controllers;

/// <summary>
/// CRUD del recurso "reservas".
///
/// Escrituras (POST/PUT/DELETE) exigen token de Keycloak con el rol de la política
/// "Escritura"; lecturas (GET) quedan públicas (decisión documentada en el README).
/// La validación de la entrada la resuelve [ApiController] con DataAnnotations del DTO.
/// </summary>
[ApiController]
[Route("reservas")]
public class ReservasController : ControllerBase
{
    private readonly RestaurantContext _db;

    public ReservasController(RestaurantContext db) => _db = db;

    // GET /reservas  |  GET /reservas?fecha=2026-08-20
    [HttpGet]
    [AllowAnonymous]
    public async Task<ActionResult<IEnumerable<ReservaDto>>> Listar(
        [FromQuery] DateOnly? fecha,
        CancellationToken ct)
    {
        IQueryable<Models.Reserva> query = _db.Reservas.AsNoTracking();

        if (fecha is not null)
        {
            query = query.Where(r => r.Fecha == fecha.Value);
        }

        var reservas = await query
            .OrderBy(r => r.Fecha)
            .ThenBy(r => r.Hora)
            .ToListAsync(ct);

        return Ok(reservas.Select(ReservaDto.Desde));
    }

    // GET /reservas/{id}
    [HttpGet("{id:int}")]
    [AllowAnonymous]
    public async Task<ActionResult<ReservaDto>> ObtenerPorId(int id, CancellationToken ct)
    {
        var reserva = await _db.Reservas.AsNoTracking()
            .FirstOrDefaultAsync(r => r.Id == id, ct);

        return reserva is null
            ? NotFound(new { message = $"Reserva {id} no encontrada." })
            : Ok(ReservaDto.Desde(reserva));
    }

    // POST /reservas -> 201 (o 400/401/403, resueltos antes de llegar aquí)
    [HttpPost]
    [Authorize(Policy = "Escritura")]
    public async Task<ActionResult<ReservaDto>> Crear(
        [FromBody] ReservaInputDto dto,
        CancellationToken ct)
    {
        var reserva = dto.AEntidad();
        _db.Reservas.Add(reserva);
        await _db.SaveChangesAsync(ct);

        return CreatedAtAction(
            nameof(ObtenerPorId),
            new { id = reserva.Id },
            ReservaDto.Desde(reserva));
    }

    // PUT /reservas/{id} -> 200 | 404
    [HttpPut("{id:int}")]
    [Authorize(Policy = "Escritura")]
    public async Task<ActionResult<ReservaDto>> Actualizar(
        int id,
        [FromBody] ReservaInputDto dto,
        CancellationToken ct)
    {
        var reserva = await _db.Reservas.FirstOrDefaultAsync(r => r.Id == id, ct);

        if (reserva is null)
        {
            return NotFound(new { message = $"Reserva {id} no encontrada." });
        }

        dto.AplicarA(reserva);
        await _db.SaveChangesAsync(ct);

        return Ok(ReservaDto.Desde(reserva));
    }

    // DELETE /reservas/{id} -> 204 | 404
    [HttpDelete("{id:int}")]
    [Authorize(Policy = "Escritura")]
    public async Task<IActionResult> Eliminar(int id, CancellationToken ct)
    {
        var reserva = await _db.Reservas.FirstOrDefaultAsync(r => r.Id == id, ct);

        if (reserva is null)
        {
            return NotFound(new { message = $"Reserva {id} no encontrada." });
        }

        _db.Reservas.Remove(reserva);
        await _db.SaveChangesAsync(ct);

        return NoContent();
    }
}
