const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const {
    EgressClient,
    RoomServiceClient,
    EncodedFileOutput,
    S3Upload,
    EncodingOptions,
    AudioCodec,
    VideoCodec
} = require('livekit-server-sdk');
const { Client: MinioClient } = require('minio');
const Database = require('better-sqlite3');
const path = require('path');

const app = express();

// Middleware
app.use(helmet());
app.use(cors());
app.use(morgan('combined'));
app.use(express.json());

// Configuration from environment variables
const config = {
    livekitUrl: process.env.LIVEKIT_URL || 'wss://livekit.market.implica.ru',
    livekitApiKey: process.env.LIVEKIT_API_KEY || 'devkey',
    livekitApiSecret: process.env.LIVEKIT_API_SECRET || 'secret123456789012345678901234567890',
    s3Endpoint: process.env.S3_ENDPOINT || 'http://minio.minio.svc.cluster.local:9000',
    s3AccessKey: process.env.S3_ACCESS_KEY || 'minioadmin',
    s3SecretKey: process.env.S3_SECRET_KEY || 'MinioAdmin2026!',
    s3Bucket: process.env.S3_BUCKET || 'livekit-recordings',
    dbPath: process.env.DB_PATH || '/data/recordings.db',
    port: parseInt(process.env.PORT, 10) || 3001
};

// Initialize SQLite Database
const db = new Database(config.dbPath);

// Create tables for recording metadata
db.exec(`
    CREATE TABLE IF NOT EXISTS recording_metadata (
        egress_id TEXT PRIMARY KEY,
        room_name TEXT NOT NULL,
        matrix_room_id TEXT,
        participants TEXT,
        initiated_by TEXT,
        filepath TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        ended_at DATETIME,
        duration INTEGER,
        file_size INTEGER
    );

    CREATE INDEX IF NOT EXISTS idx_matrix_room_id ON recording_metadata(matrix_room_id);
    CREATE INDEX IF NOT EXISTS idx_initiated_by ON recording_metadata(initiated_by);
    CREATE INDEX IF NOT EXISTS idx_created_at ON recording_metadata(created_at);
`);

console.log('SQLite database initialized');

// Prepared statements for better performance
const insertMetadata = db.prepare(`
    INSERT INTO recording_metadata (egress_id, room_name, matrix_room_id, participants, initiated_by, filepath, created_at)
    VALUES (?, ?, ?, ?, ?, ?, datetime('now'))
`);

const updateMetadataOnStop = db.prepare(`
    UPDATE recording_metadata
    SET ended_at = datetime('now'),
        duration = ?,
        file_size = ?
    WHERE egress_id = ?
`);

const getMetadataByEgressId = db.prepare(`
    SELECT * FROM recording_metadata WHERE egress_id = ?
`);

const getMetadataByFilters = db.prepare(`
    SELECT * FROM recording_metadata
    WHERE 1=1
    AND (? IS NULL OR matrix_room_id = ?)
    AND (? IS NULL OR participants LIKE '%' || ? || '%')
    AND (? IS NULL OR created_at >= ?)
    AND (? IS NULL OR created_at <= ?)
    ORDER BY created_at DESC
    LIMIT ? OFFSET ?
`);

// Initialize LiveKit Clients
const egressClient = new EgressClient(
    config.livekitUrl,
    config.livekitApiKey,
    config.livekitApiSecret
);

const roomClient = new RoomServiceClient(
    config.livekitUrl,
    config.livekitApiKey,
    config.livekitApiSecret
);

// Initialize MinIO Client
const minioClient = new MinioClient({
    endPoint: config.s3Endpoint.replace(/^https?:\/\//, '').split(':')[0],
    port: parseInt(config.s3Endpoint.split(':')[2] || '9000'),
    useSSL: false,
    accessKey: config.s3AccessKey,
    secretKey: config.s3SecretKey
});

// Create router for API endpoints
const router = express.Router();

// Health check
router.get('/health', (req, res) => {
    res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// Helper function to find active room
async function findActiveRoom(requestedRoomName) {
    try {
        const rooms = await roomClient.listRooms();
        const activeRoomNames = rooms.map(r => r.name);

        console.log(`Requested room: ${requestedRoomName}, Active rooms: ${activeRoomNames.join(', ')}`);

        if (activeRoomNames.includes(requestedRoomName)) {
            return { roomName: requestedRoomName, found: true };
        }

        if (activeRoomNames.length === 1) {
            console.log(`Auto-selecting only active room: ${activeRoomNames[0]}`);
            return { roomName: activeRoomNames[0], found: true };
        }

        return {
            roomName: null,
            found: false,
            availableRooms: activeRoomNames
        };
    } catch (error) {
        console.error('Error finding active room:', error);
        return { roomName: requestedRoomName, found: false };
    }
}

// Helper function to get file size from MinIO
async function getFileSize(filename) {
    try {
        const stat = await minioClient.statObject(config.s3Bucket, filename);
        return stat.size;
    } catch (error) {
        console.error('Error getting file size:', error);
        return null;
    }
}

// Get all audio track IDs from room participants
async function getAudioTrackIds(roomName) {
    try {
        const participants = await roomClient.listParticipants(roomName);
        const audioTrackIds = [];

        console.log(`[TRACKS] Room ${roomName} has ${participants.length} participants`);

        for (const participant of participants) {
            console.log(`[TRACKS] Participant: ${participant.identity}, tracks: ${JSON.stringify(participant.tracks?.map(t => ({sid: t.sid, type: t.type, source: t.source})))}`);

            if (participant.tracks) {
                for (const track of participant.tracks) {
                    // Track type can be: AUDIO=1, VIDEO=2 (protobuf enum)
                    // Also check source: MICROPHONE=1, CAMERA=2, SCREEN_SHARE=3, etc
                    const isAudio = track.type === 1 || track.type === 'AUDIO' || track.source === 1 || track.source === 'MICROPHONE';
                    if (isAudio && track.sid) {
                        audioTrackIds.push(track.sid);
                        console.log(`[TRACKS] Found audio track: ${track.sid}`);
                    }
                }
            }
        }

        console.log(`[TRACKS] Total audio tracks found: ${audioTrackIds.length}`);
        return audioTrackIds;
    } catch (error) {
        console.error('Error getting audio tracks:', error);
        return [];
    }
}

// Start recording - EXTENDED with metadata
router.post('/api/recording/start', async (req, res) => {
    const {
        roomName: requestedRoomName,
        layout = 'grid-dark',
        matrixRoomId,
        participants,
        initiatedBy
    } = req.body;

    if (!requestedRoomName) {
        return res.status(400).json({
            success: false,
            error: 'roomName is required'
        });
    }

    try {
        const roomResult = await findActiveRoom(requestedRoomName);

        if (!roomResult.found) {
            const errorMsg = roomResult.availableRooms
                ? `Room '${requestedRoomName}' not found. Available rooms: ${roomResult.availableRooms.join(', ')}`
                : `Room '${requestedRoomName}' not found and no active rooms available`;

            return res.status(404).json({
                success: false,
                error: errorMsg,
                availableRooms: roomResult.availableRooms || []
            });
        }

        const roomName = roomResult.roomName;
        const timestamp = Date.now();
        // Audio-only recording with AAC codec for iOS compatibility
        // LiveKit adds .mp4 extension automatically, so we just use base name
        const filepath = `recordings/${roomName}_${timestamp}`;

        const fileOutput = new EncodedFileOutput({
            filepath: filepath,
            output: {
                case: 's3',
                value: new S3Upload({
                    accessKey: config.s3AccessKey,
                    secret: config.s3SecretKey,
                    endpoint: config.s3Endpoint,
                    bucket: config.s3Bucket,
                    forcePathStyle: true
                })
            }
        });

        // Audio-only encoding options - AAC for iOS compatibility (AVPlayer doesn't support OPUS)
        const encodingOpts = new EncodingOptions({
            audioCodec: AudioCodec.AAC,
            audioBitrate: 128000,      // 128kbps for clear audio
            audioFrequency: 48000      // 48kHz sample rate
        });

        // Use Room Composite with AAC codec
        // Note: Track Composite is faster but has issues with track validation
        // Room Composite takes ~5 sec to start (headless Chrome) but is reliable
        console.log(`Using Room Composite for room: ${roomName}`);
        const info = await egressClient.startRoomCompositeEgress(roomName, fileOutput, {
            layout: layout,
            encodingOptions: encodingOpts,
            audioOnly: true
        });

        // Save metadata to SQLite
        const participantsJson = participants ? JSON.stringify(participants) : null;
        insertMetadata.run(
            info.egressId,
            roomName,
            matrixRoomId || null,
            participantsJson,
            initiatedBy || null,
            filepath
        );

        console.log(`Recording started for room ${roomName}, egressId: ${info.egressId}, matrixRoomId: ${matrixRoomId}`);

        res.json({
            success: true,
            egressId: info.egressId,
            status: info.status,
            roomName: roomName,
            requestedRoomName: requestedRoomName,
            matrixRoomId: matrixRoomId,
            participants: participants,
            filepath: filepath
        });
    } catch (error) {
        console.error('Failed to start recording:', error);
        res.status(500).json({
            success: false,
            error: error.message
        });
    }
});

// Stop recording - UPDATE metadata with duration
router.post('/api/recording/stop', async (req, res) => {
    const { egressId } = req.body;

    if (!egressId) {
        return res.status(400).json({
            success: false,
            error: 'egressId is required'
        });
    }

    try {
        const info = await egressClient.stopEgress(egressId);

        // Calculate duration and get file size
        const metadata = getMetadataByEgressId.get(egressId);
        let duration = null;
        let fileSize = null;

        if (metadata) {
            const startTime = new Date(metadata.created_at).getTime();
            const endTime = Date.now();
            duration = Math.round((endTime - startTime) / 1000);

            // Get file size from MinIO
            if (metadata.filepath) {
                fileSize = await getFileSize(metadata.filepath);
            }

            // Update metadata
            updateMetadataOnStop.run(duration, fileSize, egressId);
        }

        console.log(`Recording stopped, egressId: ${egressId}, duration: ${duration}s`);

        res.json({
            success: true,
            egressId: egressId,
            status: info.status,
            duration: duration,
            fileSize: fileSize
        });
    } catch (error) {
        console.error('Failed to stop recording:', error);
        res.status(500).json({
            success: false,
            error: error.message
        });
    }
});

// Get recording status
router.get('/api/recording/status/:egressId', async (req, res) => {
    const { egressId } = req.params;

    try {
        const list = await egressClient.listEgress({ egressId: egressId });
        const egress = list.find(e => e.egressId === egressId);

        if (!egress) {
            return res.status(404).json({
                success: false,
                error: 'Egress not found'
            });
        }

        // Get metadata from database
        const metadata = getMetadataByEgressId.get(egressId);

        res.json({
            success: true,
            egress: {
                egressId: egress.egressId,
                roomName: egress.roomName,
                status: egress.status,
                startedAt: egress.startedAt ? new Date(Number(egress.startedAt) / 1000000).toISOString() : null,
                endedAt: egress.endedAt ? new Date(Number(egress.endedAt) / 1000000).toISOString() : null,
                matrixRoomId: metadata?.matrix_room_id,
                participants: metadata?.participants ? JSON.parse(metadata.participants) : null,
                initiatedBy: metadata?.initiated_by,
                duration: metadata?.duration,
                fileSize: metadata?.file_size
            }
        });
    } catch (error) {
        console.error('Failed to get recording status:', error);
        res.status(500).json({
            success: false,
            error: error.message
        });
    }
});

// List recordings - EXTENDED with metadata and filtering
router.get('/api/recording/list', async (req, res) => {
    const {
        roomName,
        matrixRoomId,
        userId,
        from,
        to,
        limit = 50,
        offset = 0
    } = req.query;

    try {
        // Get egress list from LiveKit
        const options = roomName ? { roomName } : {};
        const egressList = await egressClient.listEgress(options);

        // Create a map of egress data
        const egressMap = new Map();
        egressList.forEach(e => {
            egressMap.set(e.egressId, e);
        });

        // Get metadata from database with filters
        const limitNum = parseInt(limit) || 50;
        const offsetNum = parseInt(offset) || 0;

        // Query all metadata and filter
        const allMetadata = db.prepare(`
            SELECT * FROM recording_metadata
            WHERE (? IS NULL OR matrix_room_id = ?)
            AND (? IS NULL OR participants LIKE '%' || ? || '%')
            AND (? IS NULL OR created_at >= ?)
            AND (? IS NULL OR created_at <= ?)
            ORDER BY created_at DESC
            LIMIT ? OFFSET ?
        `).all(
            matrixRoomId || null, matrixRoomId || null,
            userId || null, userId || null,
            from || null, from || null,
            to || null, to || null,
            limitNum, offsetNum
        );

        // Combine egress data with metadata
        const recordings = allMetadata.map(meta => {
            const egress = egressMap.get(meta.egress_id);
            const participants = meta.participants ? JSON.parse(meta.participants) : null;

            return {
                egressId: meta.egress_id,
                roomName: meta.room_name,
                matrixRoomId: meta.matrix_room_id,
                participants: participants,
                initiatedBy: meta.initiated_by,
                status: egress?.status || 3, // 3 = completed if not in active egress list
                startedAt: meta.created_at,
                endedAt: meta.ended_at,
                duration: meta.duration,
                fileSize: meta.file_size,
                filepath: meta.filepath
            };
        });

        // If no metadata but we have egress records, include them too
        if (recordings.length === 0 && !matrixRoomId && !userId) {
            const legacyRecordings = egressList.map(e => ({
                egressId: e.egressId,
                roomName: e.roomName,
                matrixRoomId: null,
                participants: null,
                initiatedBy: null,
                status: e.status,
                startedAt: e.startedAt ? new Date(Number(e.startedAt) / 1000000).toISOString() : null,
                endedAt: e.endedAt ? new Date(Number(e.endedAt) / 1000000).toISOString() : null,
                duration: null,
                fileSize: null
            }));

            return res.json({
                success: true,
                recordings: legacyRecordings,
                total: legacyRecordings.length,
                limit: limitNum,
                offset: offsetNum
            });
        }

        // Count total for pagination
        const countResult = db.prepare(`
            SELECT COUNT(*) as total FROM recording_metadata
            WHERE (? IS NULL OR matrix_room_id = ?)
            AND (? IS NULL OR participants LIKE '%' || ? || '%')
            AND (? IS NULL OR created_at >= ?)
            AND (? IS NULL OR created_at <= ?)
        `).get(
            matrixRoomId || null, matrixRoomId || null,
            userId || null, userId || null,
            from || null, from || null,
            to || null, to || null
        );

        res.json({
            success: true,
            recordings: recordings,
            total: countResult.total,
            limit: limitNum,
            offset: offsetNum
        });
    } catch (error) {
        console.error('Failed to list recordings:', error);
        res.status(500).json({
            success: false,
            error: error.message
        });
    }
});

// iOS-compatible short paths
router.post('/start', async (req, res) => {
    // Forward to main handler
    req.url = '/api/recording/start';
    router.handle(req, res);
});

router.post('/stop', async (req, res) => {
    req.url = '/api/recording/stop';
    router.handle(req, res);
});

router.get('/status/:egressId', async (req, res) => {
    req.url = `/api/recording/status/${req.params.egressId}`;
    router.handle(req, res);
});

router.get('/list', async (req, res) => {
    req.url = '/api/recording/list';
    router.handle(req, res);
});

// Proxy endpoint to stream recordings from MinIO
router.get('/api/recording/play/:egressId', async (req, res) => {
    const { egressId } = req.params;

    console.log(`[PROXY] Requested egressId: ${egressId}`);

    try {
        // First try to get actual filename from egress (most reliable)
        let filename = null;
        try {
            const list = await egressClient.listEgress({ egressId: egressId });
            const egress = list.find(e => e.egressId === egressId);
            filename = egress?.file?.filename || egress?.fileResults?.[0]?.filename;
        } catch (e) {
            console.log('[PROXY] Could not get filename from egress:', e.message);
        }

        // Fallback to metadata filepath (add .mp4 as LiveKit adds it automatically)
        if (!filename) {
            const metadata = getMetadataByEgressId.get(egressId);
            if (metadata?.filepath) {
                // LiveKit always adds .mp4 extension to the output file
                filename = metadata.filepath.endsWith('.mp4') ? metadata.filepath : metadata.filepath + '.mp4';
            }
        }

        if (!filename) {
            console.log(`[PROXY] Recording not available`);
            return res.status(404).json({
                success: false,
                error: 'Recording not found or file unavailable'
            });
        }

        console.log(`[PROXY] Fetching from MinIO: bucket=${config.s3Bucket}, file=${filename}`);

        // Get object stats for Content-Length
        const stat = await minioClient.statObject(config.s3Bucket, filename);

        // Handle range requests for video seeking
        const range = req.headers.range;
        if (range) {
            const parts = range.replace(/bytes=/, '').split('-');
            const start = parseInt(parts[0], 10);
            const end = parts[1] ? parseInt(parts[1], 10) : stat.size - 1;
            const chunksize = (end - start) + 1;

            res.writeHead(206, {
                'Content-Range': `bytes ${start}-${end}/${stat.size}`,
                'Accept-Ranges': 'bytes',
                'Content-Length': chunksize,
                'Content-Type': 'audio/mp4'
            });

            const dataStream = await minioClient.getObject(config.s3Bucket, filename, { offset: start, length: chunksize });
            dataStream.pipe(res);
        } else {
            res.setHeader('Content-Type', 'audio/mp4');
            res.setHeader('Content-Length', stat.size);
            res.setHeader('Accept-Ranges', 'bytes');

            const dataStream = await minioClient.getObject(config.s3Bucket, filename);
            dataStream.pipe(res);
        }
    } catch (error) {
        console.error('[PROXY] Error:', error);
        res.status(500).json({
            success: false,
            error: error.message
        });
    }
});

// Short path for play
router.get('/play/:egressId', async (req, res) => {
    req.url = `/api/recording/play/${req.params.egressId}`;
    router.handle(req, res);
});

// Mount router at both root and /recording-api for K8s ingress compatibility
app.use('/', router);
app.use('/recording-api', router);

// Start server
app.listen(config.port, '0.0.0.0', () => {
    console.log(`Recording API ready on port ${config.port}`);
    console.log(`Database: ${config.dbPath}`);
});
