/**
 * Session management for chunked sync operations
 * Uses write-on-arrival: chunks are written to disk immediately,
 * only lightweight flat metadata is kept in memory.
 */

import { RobloxInstance } from "./types/roblox";
import { randomUUID } from "crypto";
import { FileSystemWriter } from "./file-system/writer";
import { IndexNode, FlatMetaEntry, extractFlatMetadata, buildIndexFromFlatMetadata } from "./file-system/index-builder";
import { logger } from "./utils/logger";

export interface SyncSession {
  id: string;
  startedAt: Date;
  lastActivityAt: Date;
  writer: FileSystemWriter;
  flatIndex: Map<string, FlatMetaEntry>; // flat path -> {name, className}
  deepChunkCount: number;
  serviceCount: number;
  watcherPaused: boolean;
}

// Write progress tracking
export interface WriteProgressInfo {
  phase: "pending" | "preparing" | "writing" | "complete" | "error";
  filesWritten: number;
  totalFiles: number;
  currentService?: string;
  error?: string;
}

// Active sessions storage
const sessions = new Map<string, SyncSession>();

// Write progress storage (separate from sessions for status polling)
const writeProgress = new Map<string, WriteProgressInfo>();

// Session timeout after the last received chunk.
const SESSION_TIMEOUT_MS = 10 * 60 * 1000;

// Callback to resume watcher on session cleanup
type WatcherResumeCallback = () => void;
const watcherResumeCallbacks = new Map<string, WatcherResumeCallback>();
const sessionTimeouts = new Map<string, NodeJS.Timeout>();

function cleanupSession(session: SyncSession): void {
  const resumeCallback = watcherResumeCallbacks.get(session.id);
  if (resumeCallback && session.watcherPaused) {
    resumeCallback();
  }
  watcherResumeCallbacks.delete(session.id);
  sessions.delete(session.id);
  const timeout = sessionTimeouts.get(session.id);
  if (timeout) {
    clearTimeout(timeout);
    sessionTimeouts.delete(session.id);
  }
}

function scheduleSessionCleanup(session: SyncSession): void {
  const existing = sessionTimeouts.get(session.id);
  if (existing) {
    clearTimeout(existing);
  }

  const timeout = setTimeout(() => {
    if (sessions.has(session.id)) {
      logger.info(`Session ${session.id} expired after inactivity and was cleaned up`);
      cleanupSession(session);
    }
  }, SESSION_TIMEOUT_MS);

  sessionTimeouts.set(session.id, timeout);
}

/**
 * Create a new sync session
 */
export function createSession(
  writer: FileSystemWriter,
  watcherPaused: boolean,
  onWatcherResume?: WatcherResumeCallback
): SyncSession {
  const session: SyncSession = {
    id: randomUUID(),
    startedAt: new Date(),
    lastActivityAt: new Date(),
    writer,
    flatIndex: new Map(),
    deepChunkCount: 0,
    serviceCount: 0,
    watcherPaused,
  };

  sessions.set(session.id, session);

  if (onWatcherResume) {
    watcherResumeCallbacks.set(session.id, onWatcherResume);
  }

  scheduleSessionCleanup(session);

  return session;
}

/**
 * Mark a session as active and reset its inactivity timeout.
 */
export function refreshSession(sessionId: string): boolean {
  const session = sessions.get(sessionId);
  if (!session) {
    return false;
  }

  session.lastActivityAt = new Date();
  scheduleSessionCleanup(session);
  return true;
}

/**
 * Get an existing session
 */
export function getSession(sessionId: string): SyncSession | undefined {
  return sessions.get(sessionId);
}

/**
 * Add service index metadata (flat — no recursive Map trees)
 */
export function addServiceMetadata(
  sessionId: string,
  _serviceName: string,
  serviceData: RobloxInstance
): boolean {
  const session = sessions.get(sessionId);
  if (!session) {
    return false;
  }
  refreshSession(sessionId);

  // Extract flat metadata entries and merge into session's flat index
  const flat = extractFlatMetadata(serviceData, "");
  for (const [key, value] of flat) {
    session.flatIndex.set(key, value);
  }

  session.serviceCount++;
  return true;
}

/**
 * Add instance tree metadata at a path in the flat index
 * (for deep chunks — stores flat path entries, no recursive Maps)
 */
export function addInstanceTreeMetadata(
  sessionId: string,
  parentPath: string,
  instanceData: RobloxInstance
): boolean {
  const session = sessions.get(sessionId);
  if (!session) {
    return false;
  }
  refreshSession(sessionId);

  // Extract flat metadata with the parent path as prefix
  const flat = extractFlatMetadata(instanceData, parentPath);
  for (const [key, value] of flat) {
    session.flatIndex.set(key, value);
  }

  session.deepChunkCount++;
  return true;
}

/**
 * Get the index data for building index.json.
 * Reconstructs the IndexNode tree from flat metadata (done once at completion).
 */
export function getIndexData(sessionId: string): Map<string, IndexNode> | null {
  const session = sessions.get(sessionId);
  if (!session) {
    return null;
  }
  return buildIndexFromFlatMetadata(session.flatIndex);
}

/**
 * Delete a session (cleanup)
 */
export function deleteSession(sessionId: string): void {
  const timeout = sessionTimeouts.get(sessionId);
  if (timeout) {
    clearTimeout(timeout);
    sessionTimeouts.delete(sessionId);
  }
  watcherResumeCallbacks.delete(sessionId);
  sessions.delete(sessionId);
}

/**
 * Get session progress for logging
 */
export function getSessionProgress(sessionId: string): string {
  const session = sessions.get(sessionId);
  if (!session) {
    return "Session not found";
  }

  const deepProgress =
    session.deepChunkCount > 0 ? ` | Deep chunks: ${session.deepChunkCount}` : "";

  return `Services: ${session.serviceCount}${deepProgress}`;
}

/**
 * Initialize write progress for a session
 */
export function initWriteProgress(sessionId: string): void {
  writeProgress.set(sessionId, {
    phase: "pending",
    filesWritten: 0,
    totalFiles: 0,
  });
}

/**
 * Update write progress for a session
 */
export function updateWriteProgress(
  sessionId: string,
  progress: Partial<WriteProgressInfo>
): void {
  const current = writeProgress.get(sessionId) || {
    phase: "pending" as const,
    filesWritten: 0,
    totalFiles: 0,
  };
  writeProgress.set(sessionId, { ...current, ...progress });
}

/**
 * Get write progress for a session
 */
export function getWriteProgress(sessionId: string): WriteProgressInfo | null {
  return writeProgress.get(sessionId) || null;
}

/**
 * Clear write progress for a session
 */
export function clearWriteProgress(sessionId: string): void {
  // Keep progress around for a bit so the client can see the final state
  setTimeout(() => {
    writeProgress.delete(sessionId);
  }, 60000); // Clean up after 1 minute
}
