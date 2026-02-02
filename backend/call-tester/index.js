#!/usr/bin/env node
const { RoomServiceClient, AccessToken, EgressClient } = require('livekit-server-sdk');
const axios = require('axios');

// Configuration
const config = {
    livekitUrl: process.env.LIVEKIT_URL || 'ws://localhost:7880',
    livekitApiKey: process.env.LIVEKIT_API_KEY || 'devkey',
    livekitApiSecret: process.env.LIVEKIT_API_SECRET || 'secret',
    recordingApiUrl: process.env.RECORDING_API_URL || 'http://localhost:3001'
};

// Initialize LiveKit clients
const roomClient = new RoomServiceClient(
    config.livekitUrl.replace('ws://', 'http://').replace('wss://', 'https://'),
    config.livekitApiKey,
    config.livekitApiSecret
);

const egressClient = new EgressClient(
    config.livekitUrl.replace('ws://', 'http://').replace('wss://', 'https://'),
    config.livekitApiKey,
    config.livekitApiSecret
);

// Generate participant token
function generateToken(roomName, participantName) {
    const at = new AccessToken(config.livekitApiKey, config.livekitApiSecret, {
        identity: participantName,
        ttl: '10m'
    });

    at.addGrant({
        roomJoin: true,
        room: roomName,
        canPublish: true,
        canSubscribe: true
    });

    return at.toJwt();
}

// Create test room
async function createRoom(roomName) {
    console.log(`\n📝 Creating room: ${roomName}`);
    try {
        const room = await roomClient.createRoom({
            name: roomName,
            emptyTimeout: 300,
            maxParticipants: 10
        });
        console.log(`✅ Room created: ${room.sid}`);
        return room;
    } catch (error) {
        if (error.message.includes('already exists')) {
            console.log(`ℹ️  Room already exists`);
            return { name: roomName };
        }
        throw error;
    }
}

// List participants in room
async function listParticipants(roomName) {
    try {
        const participants = await roomClient.listParticipants(roomName);
        console.log(`\n👥 Participants in ${roomName}:`, participants.length);
        participants.forEach(p => {
            console.log(`  - ${p.identity} (${p.state})`);
        });
        return participants;
    } catch (error) {
        console.log(`❌ Failed to list participants: ${error.message}`);
        return [];
    }
}

// Start recording via Recording API
async function startRecording(roomName) {
    console.log(`\n🎥 Starting recording for: ${roomName}`);
    try {
        const response = await axios.post(
            `${config.recordingApiUrl}/api/recording/start`,
            { roomName },
            { timeout: 10000 }
        );

        if (response.data.success) {
            console.log(`✅ Recording started: ${response.data.egressId}`);
            return response.data;
        } else {
            console.log(`❌ Recording failed:`, response.data);
            return null;
        }
    } catch (error) {
        console.log(`❌ Recording API error: ${error.message}`);
        if (error.response) {
            console.log(`   Status: ${error.response.status}`);
            console.log(`   Data:`, error.response.data);
        }
        return null;
    }
}

// Stop recording
async function stopRecording(egressId) {
    console.log(`\n⏹️  Stopping recording: ${egressId}`);
    try {
        const response = await axios.post(
            `${config.recordingApiUrl}/api/recording/stop`,
            { egressId },
            { timeout: 10000 }
        );

        if (response.data.success) {
            console.log(`✅ Recording stopped`);
            return response.data;
        } else {
            console.log(`❌ Stop failed:`, response.data);
            return null;
        }
    } catch (error) {
        console.log(`❌ Stop recording error: ${error.message}`);
        return null;
    }
}

// Get recording status
async function getRecordingStatus(egressId) {
    try {
        const response = await axios.get(
            `${config.recordingApiUrl}/api/recording/status/${egressId}`,
            { timeout: 5000 }
        );
        return response.data;
    } catch (error) {
        console.log(`❌ Status check error: ${error.message}`);
        return null;
    }
}

// Main test function
async function runTest() {
    const roomName = `test-room-${Date.now()}`;
    const participantName = 'test-participant-1';

    console.log(`\n🧪 LiveKit Call & Recording Test`);
    console.log(`================================`);
    console.log(`LiveKit URL: ${config.livekitUrl}`);
    console.log(`Recording API: ${config.recordingApiUrl}`);
    console.log(`Room: ${roomName}`);

    try {
        // Step 1: Create room
        await createRoom(roomName);

        // Step 2: Generate token (in real test, client would use this to join)
        const token = generateToken(roomName, participantName);
        console.log(`\n🎫 Generated token for ${participantName}`);
        console.log(`   Token: ${token.substring(0, 50)}...`);

        // Step 3: Check recording API health
        console.log(`\n🏥 Checking Recording API health...`);
        try {
            const health = await axios.get(`${config.recordingApiUrl}/health`, { timeout: 5000 });
            console.log(`✅ Recording API is healthy:`, health.data);
        } catch (error) {
            console.log(`❌ Recording API health check failed: ${error.message}`);
            console.log(`   Make sure recording-api is running on port 3001`);
            console.log(`   Run: cd backend/recording-api && npm start`);
            return;
        }

        // Step 4: List current participants
        await listParticipants(roomName);

        // Step 5: Start recording (without actual participants for now)
        console.log(`\nℹ️  Note: Recording needs at least one participant publishing media`);
        const recording = await startRecording(roomName);

        if (recording && recording.egressId) {
            // Wait a bit
            console.log(`\n⏳ Waiting 5 seconds...`);
            await new Promise(resolve => setTimeout(resolve, 5000));

            // Check status
            console.log(`\n📊 Checking recording status...`);
            const status = await getRecordingStatus(recording.egressId);
            if (status && status.success) {
                console.log(`   Status:`, status.egress.status);
            }

            // Stop recording
            await stopRecording(recording.egressId);
        }

        // Step 6: List all recordings
        console.log(`\n📋 Listing all recordings...`);
        try {
            const list = await axios.get(`${config.recordingApiUrl}/api/recording/list`);
            if (list.data.success) {
                console.log(`   Total recordings: ${list.data.recordings.length}`);
                list.data.recordings.slice(0, 3).forEach(rec => {
                    console.log(`   - ${rec.roomName} (${rec.status})`);
                });
            }
        } catch (error) {
            console.log(`❌ List error: ${error.message}`);
        }

        console.log(`\n✅ Test completed!`);
        console.log(`\nNext steps:`);
        console.log(`- Use iOS app to join room: ${roomName}`);
        console.log(`- Or use lk CLI: ~/bin/lk room join --url ${config.livekitUrl} --api-key ${config.livekitApiKey} --api-secret ${config.livekitApiSecret} --room ${roomName}`);

    } catch (error) {
        console.error(`\n❌ Test failed:`, error.message);
        console.error(error.stack);
        process.exit(1);
    }
}

// Run test if called directly
if (require.main === module) {
    runTest();
}

module.exports = { runTest, generateToken, createRoom, startRecording, stopRecording };
