using System.Diagnostics;
using System.Net.Sockets;
using System.Text.Json;
using Npgsql;

// Probe modes. `write` is the acceptance-criteria probe; the other three assert
// the client-side guarantees the top-level README claims, using the same
// connection settings the real probe uses so the two cannot drift apart.
var mode = args.Length > 0 ? args[0] : "write";

var hosts = Environment.GetEnvironmentVariable("LAB2_PG_HOSTS")
    ?? throw new InvalidOperationException("LAB2_PG_HOSTS is required.");
var passfile = Environment.GetEnvironmentVariable("LAB2_PGPASS")
    ?? throw new InvalidOperationException("LAB2_PGPASS is required.");

var settings = new NpgsqlConnectionStringBuilder
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
};

return mode switch
{
    "write" => await RunWriteProbe(),
    "pool" => await RunPoolProbe(),
    "command-timeout" => await RunCommandTimeoutProbe(),
    "uncertain-write" => await RunUncertainWriteProbe(),
    _ => throw new ArgumentException(
        $"Unknown probe mode '{mode}'. Use write, pool, command-timeout, or uncertain-write.")
};

// Patroni is configured with ttl 30 and loop_wait 10, so a lost primary can take
// roughly 40 seconds to be noticed and replaced, plus promotion time. A budget
// rather than an attempt count keeps this comparable across failure modes: an
// unreachable host can cost up to the 5s Timeout per attempt, while a node whose
// postmaster was killed refuses instantly, so a fixed attempt count would cover
// very different amounts of wall clock depending on the fault.
async Task<int> RunWriteProbe()
{
    var connectBudget = TimeSpan.FromSeconds(90);
    var retryDelay = TimeSpan.FromSeconds(2);

    await using var dataSource = NpgsqlDataSource.Create(settings.ConnectionString);
    NpgsqlConnection? connection = null;
    Exception? lastConnectionError = null;
    var elapsed = Stopwatch.StartNew();
    var attempts = 0;

    while (connection is null)
    {
        attempts++;
        try
        {
            connection = await dataSource.OpenConnectionAsync();
        }
        catch (Exception error) when (IsRetryableConnectFailure(error))
        {
            lastConnectionError = error;
            // Progress goes to stderr so stdout stays a single JSON document.
            await Console.Error.WriteLineAsync(
                $"No primary available (attempt {attempts}, {elapsed.Elapsed.TotalSeconds:F0}s elapsed): {error.Message}");
            if (elapsed.Elapsed + retryDelay >= connectBudget)
                break;
            await Task.Delay(retryDelay);
        }
    }

    if (connection is null)
        throw new InvalidOperationException(
            $"Could not open an Npgsql primary connection within {connectBudget.TotalSeconds:F0}s "
            + $"({attempts} attempts).",
            lastConnectionError);

    await using (connection)
    {
        await using var identity = new NpgsqlCommand(
            "SELECT inet_server_addr()::text, pg_is_in_recovery()", connection);
        string serverAddress;
        bool isReplica;
        await using (var reader = await identity.ExecuteReaderAsync())
        {
            await reader.ReadAsync();
            serverAddress = reader.GetString(0);
            isReplica = reader.GetBoolean(1);
        }

        if (isReplica)
            throw new InvalidOperationException("Npgsql connected to a replica for a primary-only connection.");

        // Do not retry this write: a lost response could make its commit outcome
        // uncertain. The uncertain-write probe demonstrates exactly that hazard.
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

    return 0;
}

// Proves Maximum Pool Size is enforced, and that Timeout bounds how long the
// client waits for a connection rather than blocking indefinitely.
async Task<int> RunPoolProbe()
{
    var limit = settings.MaxPoolSize;
    await using var dataSource = NpgsqlDataSource.Create(settings.ConnectionString);
    var held = new List<NpgsqlConnection>();

    try
    {
        for (var i = 0; i < limit; i++)
            held.Add(await dataSource.OpenConnectionAsync());

        // The pool is full. The next request must not open one more physical
        // connection; it must wait for a free one and give up after Timeout.
        var stopwatch = Stopwatch.StartNew();
        Exception? exhaustion = null;
        try
        {
            await using var overflow = await dataSource.OpenConnectionAsync();
        }
        catch (Exception error)
        {
            exhaustion = error;
        }
        stopwatch.Stop();

        if (exhaustion is null)
            throw new InvalidOperationException(
                $"Opened a connection beyond Maximum Pool Size ({limit}); the limit is not enforced.");

        // Returning one connection must let the next request straight through,
        // which distinguishes a pool limit from a broken or saturated server.
        await held[0].DisposeAsync();
        held.RemoveAt(0);
        var recovered = Stopwatch.StartNew();
        await using (var afterRelease = await dataSource.OpenConnectionAsync())
        {
            await using var ping = new NpgsqlCommand("SELECT 1", afterRelease);
            await ping.ExecuteScalarAsync();
        }
        recovered.Stop();

        Console.WriteLine(JsonSerializer.Serialize(new
        {
            ok = true,
            maxPoolSize = limit,
            timeout = settings.Timeout,
            opened = limit,
            exhaustedAfterSeconds = Math.Round(stopwatch.Elapsed.TotalSeconds, 1),
            recoveredAfterSeconds = Math.Round(recovered.Elapsed.TotalSeconds, 1),
            exhaustionMessage = exhaustion.Message
        }));
    }
    finally
    {
        foreach (var connection in held)
            await connection.DisposeAsync();
    }

    return 0;
}

// Proves Command Timeout actually bounds a running statement. Lab 2 sets no
// server-side statement_timeout, so only the client-side value can end this.
async Task<int> RunCommandTimeoutProbe()
{
    var commandTimeout = settings.CommandTimeout;
    var sleepSeconds = commandTimeout * 3;

    await using var dataSource = NpgsqlDataSource.Create(settings.ConnectionString);
    await using var connection = await dataSource.OpenConnectionAsync();
    await using var sleep = new NpgsqlCommand($"SELECT pg_sleep({sleepSeconds})", connection);

    var stopwatch = Stopwatch.StartNew();
    Exception? timedOut = null;
    try
    {
        await sleep.ExecuteNonQueryAsync();
    }
    catch (Exception error)
    {
        timedOut = error;
    }
    stopwatch.Stop();

    if (timedOut is null)
        throw new InvalidOperationException(
            $"A {sleepSeconds}s query completed even though Command Timeout is {commandTimeout}s.");

    Console.WriteLine(JsonSerializer.Serialize(new
    {
        ok = true,
        commandTimeout,
        sleepSeconds,
        elapsedSeconds = Math.Round(stopwatch.Elapsed.TotalSeconds, 1),
        timeoutMessage = timedOut.Message
    }));

    return 0;
}

// Demonstrates the hazard the README warns about: a commit that is already
// durable whose acknowledgement never arrives. The batch commits and then
// blocks; the test harness terminates this backend during the block, so the
// write succeeded but this process can never learn that. The correct behaviour
// is to report failure and NOT reissue the write.
async Task<int> RunUncertainWriteProbe()
{
    var probeId = Environment.GetEnvironmentVariable("LAB2_PROBE_ID")
        ?? throw new InvalidOperationException("LAB2_PROBE_ID is required for the uncertain-write probe.");
    var applicationName = Environment.GetEnvironmentVariable("LAB2_APP_NAME")
        ?? throw new InvalidOperationException("LAB2_APP_NAME is required for the uncertain-write probe.");

    // The batch cannot use parameters (see below), so the id is embedded. Reject
    // anything that is not plain hex, which makes that embedding safe.
    if (probeId.Length is 0 or > 64 || !probeId.All(char.IsAsciiHexDigit))
        throw new InvalidOperationException("LAB2_PROBE_ID must be non-empty hex.");

    var builder = new NpgsqlConnectionStringBuilder(settings.ConnectionString)
    {
        ApplicationName = applicationName
    };

    await using var dataSource = NpgsqlDataSource.Create(builder.ConnectionString);
    await using var connection = await dataSource.OpenConnectionAsync();

    // A single round trip that commits and then blocks. The explicit COMMIT
    // matters: PostgreSQL wraps a multi-statement simple query in one implicit
    // transaction, so without it the INSERT would roll back when the backend is
    // terminated and there would be no uncertainty to demonstrate.
    // client_name carries a per-run marker rather than a constant. probe_id is a
    // primary key, so a retry reusing it would merely hit a duplicate-key error;
    // the realistic naive retry reissues the whole operation with a fresh id, and
    // only a per-run marker makes that visible as two rows.
    await using var batch = new NpgsqlCommand(
        $"BEGIN;\n"
        + $"INSERT INTO public.ha_probe (probe_id, client_name) VALUES ('{probeId}', 'uncertain-{probeId}');\n"
        + $"COMMIT;\n"
        + $"SELECT pg_sleep(60);",
        connection);
    batch.CommandTimeout = 0;

    await Console.Error.WriteLineAsync($"Issued commit-then-block batch for probe {probeId}");

    try
    {
        await batch.ExecuteNonQueryAsync();
    }
    catch (Exception error)
    {
        // Deliberately not retried. The COMMIT may already be durable, so
        // reissuing the INSERT could write the row a second time. All this
        // process can honestly do is report that the outcome is unknown.
        await Console.Error.WriteLineAsync(
            $"Write failed with an UNKNOWN commit outcome, NOT retrying: {error.Message}");
        return 1;
    }

    throw new InvalidOperationException(
        "The batch completed; the harness never terminated the backend, so no uncertainty was created.");
}

// A multi-host data source reports a failed connection attempt as an
// NpgsqlException wrapping an AggregateException of the per-host failures. That
// wrapper leaves NpgsqlException.IsTransient false even when every underlying
// failure is transient, so IsTransient alone never matches during a failover
// window. Unwrap the aggregate and judge the individual failures instead.
static bool IsRetryableConnectFailure(Exception error) => error switch
{
    // The server answered and rejected the attempt. Only 57P03 cannot_connect_now
    // clears on its own, while a promoted node finishes starting up.
    PostgresException postgres => postgres.SqlState == "57P03",
    TimeoutException or SocketException or IOException => true,
    AggregateException aggregate => aggregate.InnerExceptions.Any(IsRetryableConnectFailure),
    NpgsqlException { IsTransient: true } => true,
    // "No suitable host was found": no host is currently an eligible primary.
    NpgsqlException npgsql => npgsql.InnerException is null
        || IsRetryableConnectFailure(npgsql.InnerException),
    _ => false
};
