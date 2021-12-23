#include <sourcemod>

#include <gokz/core> // For getting server default mode
#include <gokz/localdb> // For GetCurrentMapID
#include <gokz/localranks> // For DB structure

#include <autoexecconfig>

#pragma newdecls required
#pragma semicolon 1

public Plugin myinfo =
{
    name = "DynTim for GOKZ",
    author = "Walliski, zer0.k",
    description = "Dynamic Timelimit based on average map completion time.",
    version = "1.1.0-LoB1",
    url = "https://github.com/zer0k-z/lob-dyntim/"
};

Database gH_DB = null;

public void OnPluginStart()
{
    CreateConVars();
}

ConVar gCV_dyntim_timelimit_min;
ConVar gCV_dyntim_timelimit_default;
ConVar gCV_dyntim_timelimit_max;
ConVar gCV_dyntim_multiplier;

void CreateConVars()
{
    AutoExecConfig_SetFile("plugins.dyntime", "sourcemod");
    AutoExecConfig_SetCreateFile(true);

    gCV_dyntim_timelimit_min = AutoExecConfig_CreateConVar("dyntim_timelimit_min", "15", "If calculated timelimit is smaller than this, use this value instead. (Minutes)", _, true, 0.0);
    gCV_dyntim_timelimit_default = AutoExecConfig_CreateConVar("dyntim_timelimit_default", "25", "Default timelimit if there is no calculated timelimit. (Minutes)", _, true, 0.0);
    gCV_dyntim_timelimit_max = AutoExecConfig_CreateConVar("dyntim_timelimit_max", "120", "If calculated timelimit is bigger than this, use this value instead. (Minutes)", _, true, 0.0);
    gCV_dyntim_multiplier = AutoExecConfig_CreateConVar("dyntim_multiplier", "1.0", "Multiply the resulting timelimit with this, before checking min and max values.");

    AutoExecConfig_ExecuteFile();
    AutoExecConfig_CleanFile();
}

public void OnAllPluginsLoaded()
{
    gH_DB = GOKZ_DB_GetDatabase();
}

public void GOKZ_DB_OnDatabaseConnect(DatabaseType DBType)
{
    gH_DB = GOKZ_DB_GetDatabase();
}

// SQL for getting average PB time, taken from GOKZ LocalRanks plugin.
char sql_getaverage[] = "\
SELECT AVG(PBTime), COUNT(*) \
    FROM \
    (SELECT MIN(Times.RunTime) AS PBTime \
    FROM Times \
    INNER JOIN MapCourses ON Times.MapCourseID=MapCourses.MapCourseID \
    INNER JOIN Players ON Times.SteamID32=Players.SteamID32 \
    WHERE Players.Cheater=0 AND MapCourses.MapID=%d \
    AND MapCourses.Course=0 AND Times.Mode=%d \
    GROUP BY Times.SteamID32) AS PBTimes";

public void GOKZ_DB_OnMapSetup(int mapID)
{
    DB_SetDynamicTimelimit(mapID);
}

void DB_SetDynamicTimelimit(int mapID)
{
    char query[1024];
    int mode = GOKZ_GetDefaultMode();
    Transaction txn = SQL_CreateTransaction();

    FormatEx(query, sizeof(query), sql_getaverage, mapID, mode);
    txn.AddQuery(query);

    SQL_ExecuteTransaction(gH_DB, txn, DB_TxnSuccess_SetDynamicTimelimit, DB_TxnFailure_Generic, _, DBPrio_High);
}

void DB_TxnSuccess_SetDynamicTimelimit(Handle db, DataPack data, int numQueries, Handle[] results, any[] queryData)
{
    if (!SQL_FetchRow(results[0]))
    {
        return;
    }
    float timeLimit;

    int mapCompletions = SQL_FetchInt(results[0], 1);
    if (mapCompletions < 5) // We dont want to base the avg time on too few times.
    {
        timeLimit = gCV_dyntim_timelimit_default.FloatValue;
    }
    else
    {
        // DB has the times in ms. We convert it to minutes.
        float averageTime = SQL_FetchInt(results[0], 0) / 1000.0 / 60.0;
        timeLimit = (averageTime + 10) * gCV_dyntim_multiplier.FloatValue;
    }

    // Make sure the values are not too high or low.
    float min = gCV_dyntim_timelimit_min.FloatValue;
    float max = gCV_dyntim_timelimit_max.FloatValue;
    timeLimit = timeLimit < min ? min : timeLimit;
    timeLimit = timeLimit > max ? max : timeLimit;
    // Unlock roundtime's 60 minutes upper cap.
    SetConVarBounds(FindConVar("mp_roundtime"), ConVarBound_Upper, true, gCV_dyntim_timelimit_max.FloatValue);

    char buffer[32];
    Format(buffer, sizeof(buffer), "mp_timelimit %f", timeLimit);
    ServerCommand(buffer);

    Format(buffer, sizeof(buffer), "mp_roundtime %f", timeLimit);
    ServerCommand(buffer);
    ServerCommand("mp_restartgame 1"); // Need to restart for Roundtime to take place.
}

// TxnFailure helper taken from GOKZ.
public void DB_TxnFailure_Generic(Handle db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    LogError("Database transaction error: %s", error);
}
