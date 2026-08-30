/**
 * Chunked sync endpoints for handling large games
 * Uses write-on-arrival: chunks are written to disk immediately as they arrive,
 * keeping memory usage flat regardless of game size.
 */

import { Request, Response } from "express";
import { RobloxInstance } from "../types/roblox";
import { SyncResponse } from "../types/api";
import { FileSystemWriter } from "../file-system/writer";
import { buildRootIndexFromMetadata, indexToJsonString } from "../file-system/index-builder";
import { updateSyncStats } from "./health";
import { getWatcher, getChangeTracker } from "./changes";
import { pathConfig } from "../config/path-config";
import { logger } from "../utils/logger";
import {
  createSession,
  getSession,
  refreshSession,
  addServiceMetadata,
  addInstanceTreeMetadata,
  getIndexData,
  deleteSession,
  getSessionProgress,
  initWriteProgress,
  updateWriteProgress,
  getWriteProgress,
  clearWriteProgress,
} from "../sync-session";

// Types for chunked sync requests
interface StartSyncResponse {
  success: boolean;
  sessionId?: string;
  error?: string;
}

interface ChunkRequest {
  sessionId: string;
  type: "service" | "workspace_chunk" | "deep_chunk";
  serviceName?: string;
  serviceData?: RobloxInstance;
  chunkIndex?: number;
  totalChunks?: number;
  children?: RobloxInstance[];
  // For deep chunks
  parentPath?: string;
  instanceData?: RobloxInstance;
}

interface ChunkResponse {
  success: boolean;
  received: boolean;
  progress?: string;
  error?: string;
}

interface CompleteSyncRequest {
  sessionId: string;
}

/**
 * POST /sync/start - Initialize a chunked sync session
 */
export async function handleSyncStart(_req: Request, res: Response): Promise<void> {
  try {
    // Create writer and prepare output directory
    const SYNCED_GAME_PATH = await pathConfig.getStoragePath();
    const writer = new FileSystemWriter(SYNCED_GAME_PATH);
    await writer.prepareOutputDirectory();

    // Enter bulk write mode to suppress all watcher events during chunked sync
    const changeTracker = getChangeTracker();
    changeTracker.beginBulkWrite();

    const watcher = getWatcher();
    if (watcher) {
      watcher.clearQueue();
    }

    const session = createSession(writer, true, () => {
      // Bulk write end callback (called on timeout cleanup)
      changeTracker.endBulkWrite();
    });

    // Initialize write progress
    initWriteProgress(session.id);
    updateWriteProgress(session.id, { phase: "writing", filesWritten: 0, totalFiles: 0 });

    logger.info(`Started chunked sync session: ${session.id}`);

    const response: StartSyncResponse = {
      success: true,
      sessionId: session.id,
    };

    res.json(response);
  } catch (error: any) {
    logger.error("Error starting sync session:", error);
    res.status(500).json({
      success: false,
      error: error.message || "Failed to start sync session",
    } as StartSyncResponse);
  }
}

/**
 * POST /sync/chunk - Receive a chunk of game data and write it to disk immediately
 */
export async function handleSyncChunk(req: Request, res: Response): Promise<void> {
  try {
    const body: ChunkRequest = req.body;

    // Validate session ID
    if (!body.sessionId) {
      res.status(400).json({
        success: false,
        received: false,
        error: "Missing sessionId",
      } as ChunkResponse);
      return;
    }

    const session = getSession(body.sessionId);
    if (!session) {
      res.status(404).json({
        success: false,
        received: false,
        error: "Session not found or expired",
      } as ChunkResponse);
      return;
    }
    refreshSession(body.sessionId);

    // Handle different chunk types
    if (body.type === "service") {
      // Validate service data
      if (!body.serviceName || !body.serviceData) {
        res.status(400).json({
          success: false,
          received: false,
          error: "Missing serviceName or serviceData for service chunk",
        } as ChunkResponse);
        return;
      }

      // Write service to disk immediately
      await session.writer.writeServiceToDisk(body.serviceData);

      // Store only lightweight index metadata (name + className)
      addServiceMetadata(body.sessionId, body.serviceName, body.serviceData);

      // Update progress
      updateWriteProgress(body.sessionId, {
        phase: "writing",
        filesWritten: session.writer.getFilesWritten(),
        currentService: body.serviceName,
      });

      logger.info(`Received & wrote service: ${body.serviceName} (session: ${body.sessionId.slice(0, 8)}...)`);
    } else if (body.type === "workspace_chunk") {
      // Validate workspace chunk data
      if (body.chunkIndex === undefined || body.totalChunks === undefined || !body.children) {
        res.status(400).json({
          success: false,
          received: false,
          error: "Missing chunkIndex, totalChunks, or children for workspace chunk",
        } as ChunkResponse);
        return;
      }

      // Write each child to disk immediately
      for (const child of body.children) {
        await session.writer.writeDeepChunkToDisk("Workspace", child);
        addInstanceTreeMetadata(body.sessionId, "Workspace", child);
      }

      // Update progress
      updateWriteProgress(body.sessionId, {
        phase: "writing",
        filesWritten: session.writer.getFilesWritten(),
      });

      if ((body.chunkIndex + 1) % 100 === 0 || body.chunkIndex + 1 === body.totalChunks) {
        logger.info(
          `Received & wrote Workspace chunk ${body.chunkIndex + 1}/${body.totalChunks} ` +
          `(session: ${body.sessionId.slice(0, 8)}...)`
        );
      }
    } else if (body.type === "deep_chunk") {
      // Validate deep chunk data
      if (!body.parentPath || !body.instanceData) {
        res.status(400).json({
          success: false,
          received: false,
          error: "Missing parentPath or instanceData for deep chunk",
        } as ChunkResponse);
        return;
      }

      // Write chunk to disk immediately at the specified path
      await session.writer.writeDeepChunkToDisk(body.parentPath, body.instanceData);

      // Store only lightweight index metadata
      addInstanceTreeMetadata(body.sessionId, body.parentPath, body.instanceData);

      // Update progress and yield to GC periodically
      const chunkCount = session.deepChunkCount;
      if (chunkCount % 50 === 0) {
        await new Promise(resolve => setImmediate(resolve));
      }
      if (chunkCount % 100 === 0) {
        updateWriteProgress(body.sessionId, {
          phase: "writing",
          filesWritten: session.writer.getFilesWritten(),
        });
        logger.info(
          `Wrote ${chunkCount} deep chunks (session: ${body.sessionId.slice(0, 8)}...)`
        );
      }
    } else {
      res.status(400).json({
        success: false,
        received: false,
        error: `Unknown chunk type: ${body.type}`,
      } as ChunkResponse);
      return;
    }

    const response: ChunkResponse = {
      success: true,
      received: true,
      progress: getSessionProgress(body.sessionId),
    };

    res.json(response);
  } catch (error: any) {
    logger.error("Error handling sync chunk:", error);
    res.status(500).json({
      success: false,
      received: false,
      error: error.message || "Failed to process chunk",
    } as ChunkResponse);
  }
}

/**
 * POST /sync/complete - Finalize chunked sync: write index.json and clean up
 * Most files are already on disk from write-on-arrival in handleSyncChunk.
 */
export async function handleSyncComplete(req: Request, res: Response): Promise<void> {
  try {
    const body: CompleteSyncRequest = req.body;

    // Validate session ID
    if (!body.sessionId) {
      res.status(400).json({
        success: false,
        error: "Missing sessionId",
      } as SyncResponse);
      return;
    }

    const session = getSession(body.sessionId);
    if (!session) {
      res.status(404).json({
        success: false,
        error: "Session not found or expired",
      } as SyncResponse);
      return;
    }
    refreshSession(body.sessionId);

    logger.info(`Completing chunked sync session: ${body.sessionId.slice(0, 8)}...`);
    logger.info(`Final progress: ${getSessionProgress(body.sessionId)}`);

    // Respond immediately for backward compatibility with plugin status polling
    res.json({
      success: true,
      started: true,
      message: "Finalizing sync. Poll /sync/status/:sessionId for progress.",
      timestamp: new Date().toISOString(),
    } as SyncResponse & { started: boolean; message: string });

    // Finalize in background (write index.json, flush, cleanup)
    setImmediate(async () => {
      try {
        // Build and write index.json from lightweight metadata
        const indexData = getIndexData(body.sessionId);
        if (indexData) {
          const index = buildRootIndexFromMetadata(indexData);
          await session.writer.writeIndexFile(indexToJsonString(index));
        }

        // Flush any remaining pending writes
        await session.writer.flushWrites();

        const filesWritten = session.writer.getFilesWritten();

        // Update stats
        updateSyncStats(filesWritten);

        // Mark as complete
        updateWriteProgress(body.sessionId, {
          phase: "complete",
          filesWritten,
        });

        logger.info(`Chunked sync complete: ${filesWritten} files written`);

        // Wait a bit for all file writes to settle
        await new Promise((resolve) => setTimeout(resolve, 500));
      } catch (writeError: any) {
        logger.error("Error finalizing sync:", writeError);
        updateWriteProgress(body.sessionId, {
          phase: "error",
          error: writeError.message || "Finalization failed",
        });
      } finally {
        // Exit bulk write mode
        const changeTracker = getChangeTracker();
        if (session.watcherPaused) {
          changeTracker.endBulkWrite();
        }

        // Delete session to free remaining metadata memory
        deleteSession(body.sessionId);

        // Keep progress available for a bit longer so client can poll final status
        setTimeout(() => {
          clearWriteProgress(body.sessionId);
        }, 60000);
      }
    });
  } catch (error: any) {
    logger.error("Error completing sync:", error);

    // Try to clean up session on error
    if (req.body.sessionId) {
      const session = getSession(req.body.sessionId);
      if (session && session.watcherPaused) {
        const changeTracker = getChangeTracker();
        changeTracker.endBulkWrite();
      }
      deleteSession(req.body.sessionId);
      updateWriteProgress(req.body.sessionId, {
        phase: "error",
        error: error.message || "Failed to complete sync",
      });
    }

    res.status(500).json({
      success: false,
      error: error.message || "Failed to complete sync",
    } as SyncResponse);
  }
}

/**
 * GET /sync/status/:sessionId - Get write progress for a session
 */
export async function handleSyncStatus(req: Request, res: Response): Promise<void> {
  try {
    const sessionId = req.params.sessionId;

    if (!sessionId) {
      res.status(400).json({
        success: false,
        error: "Missing sessionId",
      });
      return;
    }

    const progress = getWriteProgress(sessionId);

    if (!progress) {
      res.status(404).json({
        success: false,
        error: "Session not found or progress not available",
      });
      return;
    }

    res.json({
      success: true,
      ...progress,
    });
  } catch (error: any) {
    logger.error("Error getting sync status:", error);
    res.status(500).json({
      success: false,
      error: error.message || "Failed to get sync status",
    });
  }
}
