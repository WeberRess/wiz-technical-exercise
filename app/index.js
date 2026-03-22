/*
 * index.js — Todo list web application
 *
 * PDF Requirements satisfied:
 *   REQ-02: containerized app rebuilt by the candidate
 *   REQ-14: reads MongoDB URL from MONGODB_URL environment variable
 *   REQ-20: demonstrates the app works and data is stored in MongoDB
 *
 * Endpoints:
 *   GET  /           → renders the todo list UI
 *   POST /todos      → creates a new todo item
 *   GET  /api/todos  → returns all todos as JSON (used by validate.sh)
 *   GET  /health     → returns {"status":"ok"} (used by readiness probe)
 */
'use strict';
const express = require('express');
const { MongoClient, ObjectId } = require('mongodb');

const app  = express();
const PORT = 3000;

// MONGODB_URL is injected from a Kubernetes Secret (REQ-14)
// Format: mongodb://wizadmin:WizPassword123!@10.0.1.4:27017/todos?authSource=admin
const MONGO_URL = process.env.MONGODB_URL || 'mongodb://localhost:27017/todos';

let db;
MongoClient.connect(MONGO_URL, { useUnifiedTopology: true })
  .then(client => {
    db = client.db('todos');
    console.log('Connected to MongoDB at ' + MONGO_URL.replace(/:([^@]+)@/, ':***@'));
  })
  .catch(err => console.error('MongoDB connection error:', err));

app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Health check — used by Kubernetes readiness probe and validate.sh (REQ-20)
app.get('/health', (req, res) => res.json({ status: 'ok' }));

// Main UI — renders current todos
app.get('/', async (req, res) => {
  const todos = db ? await db.collection('todos').find().toArray() : [];
  const items = todos.map(t =>
    `<li>${t.text} <a href="/todos/${t._id}/delete">✕</a></li>`
  ).join('');
  res.send(`<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Wiz Todo App</title></head>
<body>
  <h1>Todo App — Wiz Technical Exercise</h1>
  <p>Candidate: ${process.env.CANDIDATE_NAME || 'unknown'}</p>
  <form method="POST" action="/todos">
    <input name="text" placeholder="New task" required>
    <button type="submit">Add</button>
  </form>
  <ul>${items}</ul>
</body>
</html>`);
});

// Create todo — used by validate.sh end-to-end test (REQ-20)
app.post('/todos', async (req, res) => {
  const text = req.body.text || req.body.title || '';
  if (!text) return res.status(400).json({ error: 'text required' });
  await db.collection('todos').insertOne({ text, createdAt: new Date() });
  res.redirect('/');
});

// JSON endpoint — used by validate.sh to verify data was stored
app.get('/api/todos', async (req, res) => {
  const todos = db ? await db.collection('todos').find().toArray() : [];
  res.json(todos);
});

// Delete todo
app.get('/todos/:id/delete', async (req, res) => {
  try { await db.collection('todos').deleteOne({ _id: new ObjectId(req.params.id) }); }
  catch (e) { /* ignore invalid id */ }
  res.redirect('/');
});

app.listen(PORT, () => console.log(`Listening on port ${PORT}`));
