static bool PauseableGameState() {
  return (g_GameState == Get5State_KnifeRound || g_GameState == Get5State_WaitingForKnifeRoundDecision ||
          g_GameState == Get5State_Live || g_GameState == Get5State_GoingLive);
}

void PauseGame(Get5Team team, Get5PauseType type) {
  if (type == Get5PauseType_None) {
    LogError("PauseGame() called with Get5PauseType_None. Please call UnpauseGame() instead.");
    UnpauseGame(team);
    return;
  }

  g_TeamReadyForUnpause[Get5Team_1] = false;
  g_TeamReadyForUnpause[Get5Team_2] = false;

  Get5MatchPausedEvent event = new Get5MatchPausedEvent(g_MatchID, g_MapNumber, team, type);

  LogDebug("Calling Get5_OnMatchPaused()");

  Call_StartForward(g_OnMatchPaused);
  Call_PushCell(event);
  Call_Finish();

  EventLogger_LogAndDeleteEvent(event);

  // Stop existing pause timer and restart it.
  delete g_PauseTimer;
  g_PauseTimer = CreateTimer(1.0, Timer_PauseTimeCheck, _, TIMER_REPEAT);
  g_LatestPauseDuration = 0;
  g_PauseType = type;
  g_PausingTeam = team;
  g_IsChangingPauseState = true;
  ServerCommand("mp_pause_match");
  CreateTimer(0.1, Timer_ResetPauseRestriction);
}

static Action Timer_ResetPauseRestriction(Handle timer, int data) {
  g_IsChangingPauseState = false;
}

void UnpauseGame(Get5Team team) {
  Get5MatchUnpausedEvent event = new Get5MatchUnpausedEvent(g_MatchID, g_MapNumber, team, g_PauseType);

  LogDebug("Calling Get5_OnMatchUnpaused()");

  Call_StartForward(g_OnMatchUnpaused);
  Call_PushCell(event);
  Call_Finish();

  EventLogger_LogAndDeleteEvent(event);

  delete g_PauseTimer;  // Immediately stop pause timer if running.
  g_PauseType = Get5PauseType_None;
  g_PausingTeam = Get5Team_None;
  g_LatestPauseDuration = 0;
  g_IsChangingPauseState = true;
  ServerCommand("mp_unpause_match");
  CreateTimer(0.1, Timer_ResetPauseRestriction);
}

bool TriggerAutomaticTechPause(Get5Team team) {
  int maxPauses = g_MaxTechPausesCvar.IntValue;
  if (g_PauseType == Get5PauseType_None && (maxPauses == 0 || maxPauses - g_TechnicalPausesUsed[team] > 0)) {
    g_TechnicalPausesUsed[team]++;
    PauseGame(team, Get5PauseType_Tech);
    Get5_MessageToAll("%t", "TechPauseAutomaticallyStarted", g_FormattedTeamNames[team]);
    return true;
  }
  return false;
}

Action Command_PauseOrUnpauseMatch(int client, const char[] command, int argc) {
  if (g_GameState == Get5State_None || (g_IsChangingPauseState && client == 0)) {
    return Plugin_Continue;
  }
  ReplyToCommand(client, "Get5 prevents calls to %s. Administrators should use sm_pause/sm_unpause.", command);
  return Plugin_Stop;
}

Action Command_TechPause(int client, int args) {
  if (client == 0) {
    // Redirect admin use of sm_tech to regular pause. We only have one type of admin pause.
    return Command_Pause(client, args);
  }

  if (!PauseableGameState()) {
    return Plugin_Handled;
  }

  Get5Team team = GetClientMatchTeam(client);
  if (!IsPlayerTeam(team)) {
    return Plugin_Handled;
  }

  if (!g_PausingEnabledCvar.BoolValue) {
    Get5_MessageToAll("%t", "PausesNotEnabled");
    return Plugin_Handled;
  }

  if (!g_AllowTechPauseCvar.BoolValue) {
    Get5_MessageToAll("%t", "TechPausesNotEnabled");
    return Plugin_Handled;
  }

  if (g_PauseType != Get5PauseType_None) {
    g_TeamReadyForUnpause[team] = false;
    LogDebug("Ignoring technical pause request as game is already paused; setting team to not ready to unpause.");
    return Plugin_Handled;
  }

  int maxTechPauses = g_MaxTechPausesCvar.IntValue;
  int maxTechPauseDuration = g_MaxTechPauseDurationCvar.IntValue;

  // Max tech pause COUNT
  if (maxTechPauses > 0) {
    if (g_TechnicalPausesUsed[team] >= maxTechPauses) {
      Get5_MessageToAll("%t", "TechPauseNoPausesRemaining", g_FormattedTeamNames[team]);
      return Plugin_Handled;
    }
  }

  // Max tech pause TIME
  if (maxTechPauseDuration > 0) {
    if (maxTechPauseDuration - g_LatestPauseDuration <= 0) {
      Get5_MessageToAll("%t", "TechPauseNoTimeRemaining", g_FormattedTeamNames[team]);
      return Plugin_Handled;
    }
  }

  g_TechnicalPausesUsed[team]++;
  PauseGame(team, Get5PauseType_Tech);

  char formattedClientName[MAX_NAME_LENGTH];
  FormatPlayerName(formattedClientName, sizeof(formattedClientName), client, team);
  Get5_MessageToAll("%t", "MatchTechPausedByTeamMessage", formattedClientName);
  if (maxTechPauses > 0) {
    Get5_MessageToAll("%t", "TechPausePausesRemaining", g_FormattedTeamNames[team],
                      maxTechPauses - g_TechnicalPausesUsed[team]);
  }
  return Plugin_Handled;
}

Action Command_Pause(int client, int args) {
  if (client == 0) {
    PauseGame(Get5Team_None, Get5PauseType_Admin);
    Get5_MessageToAll("%t", "AdminForcePauseInfoMessage");
    return Plugin_Handled;
  }

  if (!PauseableGameState()) {
    return Plugin_Handled;
  }

  Get5Team team = GetClientMatchTeam(client);
  if (!IsPlayerTeam(team)) {
    return Plugin_Handled;
  }

  if (!g_PausingEnabledCvar.BoolValue) {
    Get5_MessageToAll("%t", "PausesNotEnabled");
    return Plugin_Handled;
  }

  if (g_PauseType != Get5PauseType_None) {
    g_TeamReadyForUnpause[team] = false;
    LogDebug("Ignoring tactical pause request as game is already paused; setting team to not ready to unpause.");
    return Plugin_Handled;
  }

  int maxPauses = g_MaxTacticalPausesCvar.IntValue;

  if (!g_FixedPauseTimeCvar.BoolValue) {
    int maxPauseTime = g_MaxPauseTimeCvar.IntValue;
    if (maxPauseTime > 0 && g_TacticalPauseTimeUsed[team] >= maxPauseTime) {
      char maxPauseTimeFormatted[16];
      ConvertSecondsToMinutesAndSeconds(maxPauseTime, maxPauseTimeFormatted, sizeof(maxPauseTimeFormatted));
      Get5_Message(client, "%t", "MaxPausesTimeUsedInfoMessage", maxPauseTimeFormatted, g_FormattedTeamNames[team]);
      return Plugin_Handled;
    }
  }

  if (maxPauses > 0 && g_TacticalPausesUsed[team] >= maxPauses) {
    Get5_Message(client, "%t", "MaxPausesUsedInfoMessage", maxPauses, g_FormattedTeamNames[team]);
    return Plugin_Handled;
  }

  g_TacticalPausesUsed[team]++;
  PauseGame(team, Get5PauseType_Tactical);

  if (IsPlayer(client)) {
    char formattedClientName[MAX_NAME_LENGTH];
    FormatPlayerName(formattedClientName, sizeof(formattedClientName), client, team);
    Get5_MessageToAll("%t", "MatchPausedByTeamMessage", formattedClientName);
  }

  if (maxPauses > 0) {
    int pausesLeft = maxPauses - g_TacticalPausesUsed[team];
    if (pausesLeft >= 0) {
      Get5_MessageToAll("%t", "PausesLeftInfoMessage", g_FormattedTeamNames[team], pausesLeft);
    }
  }
  return Plugin_Handled;
}

Action Command_Unpause(int client, int args) {
  if (!IsPaused()) {
    // Game is not paused; ignore command.
    return Plugin_Handled;
  }

  if (g_PauseType == Get5PauseType_Admin && client != 0) {
    Get5_MessageToAll("%t", "UserCannotUnpauseAdmin");
    return Plugin_Handled;
  }

  // Let console force unpause
  if (client == 0) {
    UnpauseGame(Get5Team_None);
    Get5_MessageToAll("%t", "AdminForceUnPauseInfoMessage");
    return Plugin_Handled;
  }

  Get5Team team = GetClientMatchTeam(client);
  if (team == g_PausingTeam && !InFreezeTime()) {
    Get5_MessageToAll("%t", "PausingTeamCannotUnpauseUntilFreezeTime");
    return Plugin_Handled;
  } else if (!IsPlayerTeam(team)) {
    return Plugin_Handled;
  }

  g_TeamReadyForUnpause[team] = true;
  if (g_PauseType == Get5PauseType_Tech) {
    int maxTechPauseDuration = g_MaxTechPauseDurationCvar.IntValue;
    int maxTechPauses = g_MaxTechPausesCvar.IntValue;
    int techPausesUsed = g_TechnicalPausesUsed[g_PausingTeam];

    if ((maxTechPauseDuration > 0 && g_LatestPauseDuration >= maxTechPauseDuration) ||
        (maxTechPauses > 0 && techPausesUsed > maxTechPauses)) {
      UnpauseGame(team);
      if (IsPlayer(client)) {
        char formattedClientName[MAX_NAME_LENGTH];
        FormatPlayerName(formattedClientName, sizeof(formattedClientName), client, team);
        Get5_MessageToAll("%t", "MatchUnpauseInfoMessage", formattedClientName);
      }
      return Plugin_Handled;
    }
  }

  char formattedUnpauseCommand[64];
  GetChatAliasForCommand(Get5ChatCommand_Unpause, formattedUnpauseCommand, sizeof(formattedUnpauseCommand), true);
  if (g_TeamReadyForUnpause[Get5Team_1] && g_TeamReadyForUnpause[Get5Team_2]) {
    UnpauseGame(team);
    if (IsPlayer(client)) {
      char formattedClientName[MAX_NAME_LENGTH];
      FormatPlayerName(formattedClientName, sizeof(formattedClientName), client, team);
      Get5_MessageToAll("%t", "MatchUnpauseInfoMessage", formattedClientName);
    }
  } else if (!g_TeamReadyForUnpause[Get5Team_2]) {
    Get5_MessageToAll("%t", "WaitingForUnpauseInfoMessage", g_FormattedTeamNames[Get5Team_1],
                      g_FormattedTeamNames[Get5Team_2], formattedUnpauseCommand);
  } else if (!g_TeamReadyForUnpause[Get5Team_1]) {
    Get5_MessageToAll("%t", "WaitingForUnpauseInfoMessage", g_FormattedTeamNames[Get5Team_2],
                      g_FormattedTeamNames[Get5Team_1], formattedUnpauseCommand);
  }

  return Plugin_Handled;
}

static Action Timer_PauseTimeCheck(Handle timer) {
  if (timer != g_PauseTimer) {
    LogDebug("Stopping pause timer as handle was incorrect.");
    return Plugin_Stop;
  }
  if (g_PauseType == Get5PauseType_None || !IsPaused()) {
    LogDebug("Stopping pause timer as game is not paused.");
    g_PauseTimer = INVALID_HANDLE;
    return Plugin_Stop;
  }

  // Shorter local variable because g_PausingTeam for the rest of the code was just too much.
  Get5Team team = g_PausingTeam;

  if (!InFreezeTime()) {
    LogDebug("Ignoring pause counter as game is not yet frozen.");
    return Plugin_Continue;
  }

  // This is incremented no matter what and used both for fixed tactical pauses and tech pause time.
  g_LatestPauseDuration++;
  LogDebug("Incrementing pause duration. Now: %d", g_LatestPauseDuration);

  char teamString[4];
  CSTeamString(Get5TeamToCSTeam(team), teamString, sizeof(teamString));

  if (g_PauseType == Get5PauseType_Tactical) {
    int maxTacticalPauseTime = g_MaxPauseTimeCvar.IntValue;
    int maxTacticalPauses = g_MaxTacticalPausesCvar.IntValue;
    int tacticalPausesUsed = g_TacticalPausesUsed[team];

    int fixedPauseTime = g_FixedPauseTimeCvar.IntValue;
    if (fixedPauseTime > 0 && fixedPauseTime < 15) {
      fixedPauseTime = 15;  // Don't allow less than 15 second fixed pauses.
    }

    // -1 assumes unlimited.
    int timeLeft = -1;

    if (fixedPauseTime > 0) {
      timeLeft = fixedPauseTime - g_LatestPauseDuration;
      if (timeLeft <= 0) {
        g_PauseTimer = INVALID_HANDLE;
        UnpauseGame(team);
        return Plugin_Stop;
      }
    } else if (maxTacticalPauses > 0 && tacticalPausesUsed > maxTacticalPauses) {
      // The game gets unpaused if the number of maximum pauses changes to below the number of used
      // pauses while a pause is active. Kind of a weird edge-case, but it should be handled
      // gracefully.
      Get5_MessageToAll("%t", "MaxPausesUsedInfoMessage", maxTacticalPauses, g_FormattedTeamNames[g_PausingTeam]);
      g_PauseTimer = INVALID_HANDLE;
      UnpauseGame(team);
      return Plugin_Stop;
    } else if (!g_TeamReadyForUnpause[team]) {
      // If the team that called the pause has indicated they are ready, no more time should be
      // subtracted from their maximum pause time, but the timer must keep running as they could go
      // back to not-ready-for-unpause before the other team unpauses, in which case we would keep
      // counting their seconds used.
      g_TacticalPauseTimeUsed[team]++;
      LogDebug("Adding tactical pause time used for Get5Team %d. Now: %d", team, g_TacticalPauseTimeUsed[team]);
      if (maxTacticalPauseTime > 0) {
        timeLeft = maxTacticalPauseTime - g_TacticalPauseTimeUsed[team];
        if (timeLeft <= 0) {
          Get5_MessageToAll("%t", "PauseRunoutInfoMessage", g_FormattedTeamNames[team]);
          g_PauseTimer = INVALID_HANDLE;
          UnpauseGame(team);
          return Plugin_Stop;
        }
      }
    }

    char timeLeftFormatted[16] = "";
    if (timeLeft >= 0) {
      // Only format the string once; not inside the loop.
      ConvertSecondsToMinutesAndSeconds(timeLeft, timeLeftFormatted, sizeof(timeLeftFormatted));
    }

    char pauseTimeMaxFormatted[16] = "";
    if (timeLeft >= 0) {
      ConvertSecondsToMinutesAndSeconds(maxTacticalPauseTime, pauseTimeMaxFormatted, sizeof(pauseTimeMaxFormatted));
    }

    LOOP_CLIENTS(i) {
      if (IsValidClient(i)) {
        if (fixedPauseTime) {  // If fixed pause; takes precedence over total time and reuses
                               // timeLeft for simplicity
          if (maxTacticalPauses > 0) {
            // Team A (CT) tactical pause (2/4): 0:45
            PrintHintText(i, "%s (%s) %t (%d/%d): %s", g_TeamNames[team], teamString, "TacticalPauseMidSentence",
                          tacticalPausesUsed, maxTacticalPauses, timeLeftFormatted);
          } else {
            // Team A (CT) tactical pause: 0:45
            PrintHintText(i, "%s (%s) %t: %s", g_TeamNames[team], teamString, "TacticalPauseMidSentence",
                          timeLeftFormatted);
          }
        } else if (timeLeft >= 0) {  // If total time restriction
          if (maxTacticalPauses > 0) {
            // Team A (CT) tactical pause (2/4).
            // Remaining pause time: 0:45 / 3:00
            PrintHintText(i, "%s (%s) %t (%d/%d).\n%t: %s / %s", g_TeamNames[team], teamString,
                          "TacticalPauseMidSentence", tacticalPausesUsed, maxTacticalPauses, "PauseTimeRemainingPrefix",
                          timeLeftFormatted, pauseTimeMaxFormatted);
          } else {
            // Team A (CT) tactical pause.
            // Remaining pause time: 0:45 / 3:00
            PrintHintText(i, "%s (%s) %t.\n%t: %s / %s", g_TeamNames[team], teamString, "TacticalPauseMidSentence",
                          "PauseTimeRemainingPrefix", timeLeftFormatted, pauseTimeMaxFormatted);
          }
        } else {  // if no time restriction or awaiting unpause
          if (maxTacticalPauses > 0) {
            // Team A (CT) tactical pause (2/4).
            // Awaiting unpause.
            PrintHintText(i, "%s (%s) %t (%d/%d).\n%t.", g_TeamNames[team], teamString, "TacticalPauseMidSentence",
                          tacticalPausesUsed, maxTacticalPauses, "AwaitingUnpause");
          } else {
            // Team A (CT) tactical pause.
            // Awaiting unpause.
            PrintHintText(i, "%s (%s) %t.\n%t.", g_TeamNames[team], teamString, "TacticalPauseMidSentence",
                          "AwaitingUnpause");
          }
        }
      }
    }

  } else if (g_PauseType == Get5PauseType_Tech) {
    int maxTechPauseDuration = g_MaxTechPauseDurationCvar.IntValue;
    int maxTechPauses = g_MaxTechPausesCvar.IntValue;
    int techPausesUsed = g_TechnicalPausesUsed[team];

    // -1 assumes unlimited.
    int timeLeft = -1;

    // If tech pause max is reduced to below what is used, we don't want to print remaining time, as
    // anyone can unpause. We achieve this by simply skipping the time calculation if max tech
    // pauses have been exceeded.
    if (!g_TeamReadyForUnpause[team] && (maxTechPauses == 0 || techPausesUsed <= maxTechPauses)) {
      if (maxTechPauseDuration > 0) {
        timeLeft = maxTechPauseDuration - g_LatestPauseDuration;
        if (timeLeft == 0) {
          // Only print to chat when hitting 0, but keep the timer going as tech pauses don't
          // unpause on their own. The PrintHintText below will inform users that they can now
          // unpause.
          char formattedUnpauseCommand[64];
          GetChatAliasForCommand(Get5ChatCommand_Unpause, formattedUnpauseCommand, sizeof(formattedUnpauseCommand),
                                 true);
          Get5_MessageToAll("%t", "TechPauseRunoutInfoMessage", formattedUnpauseCommand);
        }
      }
    }

    char timeLeftFormatted[16] = "";
    if (timeLeft >= 0) {
      // Only format the string once; not inside the loop.
      ConvertSecondsToMinutesAndSeconds(timeLeft, timeLeftFormatted, sizeof(timeLeftFormatted));
    }

    LOOP_CLIENTS(i) {
      if (IsValidClient(i)) {
        if (timeLeft >= 0) {
          if (maxTechPauses > 0) {
            // Team A (CT) technical pause (3/4): Time remaining before anyone can unpause: 1:30
            PrintHintText(i, "%s (%s) %t (%d/%d).\n%t: %s", g_TeamNames[team], teamString, "TechnicalPauseMidSentence",
                          techPausesUsed, maxTechPauses, "TimeRemainingBeforeAnyoneCanUnpausePrefix",
                          timeLeftFormatted);
          } else {
            // Team A (CT) technical pause. Time remaining before anyone can unpause: 1:30
            PrintHintText(i, "%s (%s) %t.\n%t: %s", g_TeamNames[team], teamString, "TechnicalPauseMidSentence",
                          "TimeRemainingBeforeAnyoneCanUnpausePrefix", timeLeftFormatted);
          }
        } else {
          if (maxTechPauses > 0) {
            // Team A (CT) technical pause (3/4). Awaiting unpause.
            PrintHintText(i, "%s (%s) %t (%d/%d).\n%t.", g_TeamNames[team], teamString, "TechnicalPauseMidSentence",
                          techPausesUsed, maxTechPauses, "AwaitingUnpause");
          } else {
            // Team A (CT) technical pause. Awaiting unpause.
            PrintHintText(i, "%s (%s) %t.\n%t.", g_TeamNames[team], teamString, "TechnicalPauseMidSentence",
                          "AwaitingUnpause");
          }
        }
      }
    }

  } else if (g_PauseType == Get5PauseType_Admin) {
    LOOP_CLIENTS(i) {
      if (IsValidClient(i)) {
        PrintHintText(i, "%t", "PausedByAdministrator");
      }
    }

  } else if (g_PauseType == Get5PauseType_Backup) {
    LOOP_CLIENTS(i) {
      if (IsValidClient(i)) {
        PrintHintText(i, "%t", "PausedForBackup");
      }
    }
  }
  return Plugin_Continue;
}
