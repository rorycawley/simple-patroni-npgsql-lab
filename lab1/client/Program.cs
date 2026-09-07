using System.Text.Json;
using Npgsql;

var hosts = Environment.GetEnvironmentVariable("LAB1_PG_HOSTS")
    ?? throw new InvalidOperationException("LAB1_PG_HOSTS is required.");
var passfile = Environment.GetEnvironmentVariable("LAB1_PGPASS")
    ?? throw new InvalidOperationException("LAB1_PGPASS is required.");

var connectionString = new NpgsqlConnectionStringBuilder
{
    Host = hosts,
    Port = 5432,
    Database = "appdb",
    Username = "app_runtime",
    Passfile = passfile,
    TargetSessionAttributes = "primary",
    Timeout = 5,
    CommandTimeout = 10,
    MaxPoolSize = 20,
    SslMode = SslMode.Disable
}.ConnectionString;

await using var dataSource = NpgsqlDataSource.Create(connectionString);
NpgsqlConnection? connection = null;
Exception? lastConnectionError = null;
for (var attempt = 1; attempt <= 12; attempt++)
{
    try
    {
        connection = await dataSource.OpenConnectionAsync();
        break;
    }
    catch (Exception error) when (
        (error is TimeoutException || error is NpgsqlException { IsTransient: true }))
    {
        lastConnectionError = error;
        if (attempt < 12)
            await Task.Delay(TimeSpan.FromSeconds(2));
    }
}

if (connection is null)
    throw new InvalidOperationException(
        "Could not open an Npgsql primary connection after 12 attempts.",
        lastConnectionError);

await using (connection)
{
    await using var identity = new NpgsqlCommand(
        "SELECT inet_server_addr()::text, pg_is_in_recovery()", connection);
    await using var reader = await identity.ExecuteReaderAsync();
    await reader.ReadAsync();
    var serverAddress = reader.GetString(0);
    var isReplica = reader.GetBoolean(1);
    await reader.CloseAsync();
    if (isReplica)
        throw new InvalidOperationException("Npgsql connected to a replica for a primary-only connection.");

    // Do not retry this write: a lost response could make its commit outcome uncertain.
    var probeId = Guid.NewGuid().ToString("N");
    await using var insert = new NpgsqlCommand(
        "INSERT INTO public.ha_probe (probe_id, client_name) VALUES ($1, $2) RETURNING probe_id",
        connection);
    insert.Parameters.AddWithValue(probeId);
    insert.Parameters.AddWithValue("npgsql-acceptance-test");
    var insertedId = (string?)await insert.ExecuteScalarAsync();
    if (insertedId != probeId)
        throw new InvalidOperationException("The write probe did not return the inserted identifier.");

    Console.WriteLine(JsonSerializer.Serialize(new
    {
        ok = true,
        server = serverAddress,
        primary = true,
        probeId
    }));
}
