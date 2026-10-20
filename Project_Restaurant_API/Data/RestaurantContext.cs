using Microsoft.EntityFrameworkCore;
using Project_Restaurant_API.Models;

namespace Project_Restaurant_API.Data
{
    public class RestaurantContext : DbContext
    {
        public RestaurantContext(DbContextOptions<RestaurantContext> options)
            : base(options)
        {
        }

        public DbSet<Reserva> Reservas => Set<Reserva>();

        protected override void OnModelCreating(ModelBuilder modelBuilder)
        {
            modelBuilder.Entity<Reserva>(entity =>
            {
                entity.ToTable("reservas");
                entity.HasKey(r => r.Id);

                entity.Property(r => r.NombreCliente)
                      .HasColumnName("nombre_cliente")
                      .HasMaxLength(120)
                      .IsRequired();

                entity.Property(r => r.Fecha)
                      .HasColumnName("fecha")
                      .IsRequired();

                entity.Property(r => r.Hora)
                      .HasColumnName("hora")
                      .IsRequired();

                entity.Property(r => r.CantidadPersonas)
                      .HasColumnName("cantidad_personas")
                      .IsRequired();

                // Índice para el filtro por fecha (GET /reservas?fecha=...).
                entity.HasIndex(r => r.Fecha);
            });
        }
    }
}
