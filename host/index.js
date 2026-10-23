/**
 * whale-mini / host —— 把整个 DSH 窗口收成一只置顶的 Q 版鲸鱼娘，旁边实时显示它在想什么。
 *
 * 插件碰不到 Electron 的窗口（客户端在 sandbox renderer、宿主在独立 Node 进程，
 * app.asar 里也没有 setAlwaysOnTop），所以窗口交给一支 Swift 小助手：
 *   · 无边框毛玻璃卡片，level = .floating + canJoinAllSpaces → 压在所有窗口和全屏之上
 *   · NSRunningApplication.hide() 收起 DeepSeek Harness（等于 ⌘H，不需要任何权限）
 *   · 拖 = 移动（位置记在 ~/.dsh/whale-mini/pos.json），单击 = 回窗口
 *
 * 这里负责：图（当前皮肤的 Q 版立绘）、config.json、以及把 agent/assistant-stream 里的
 * reasoning-delta 攒成 state.json —— 小助手每 0.4s 读一次，卡片上滚的就是它的思考过程。
 * 不 import 任何 @deepseek-ai/*。
 */
import { spawn } from 'node:child_process'
import { access, mkdir, readdir, readFile, rename, stat, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const APP = path.join(HERE, '..', 'helper', 'WhaleMini.app')
/** 状态和宠物图都放在真实家目录：helper 是独立进程，认这个固定位置最稳。 */
const HOME = path.join(os.homedir(), '.dsh')
const DIR = path.join(HOME, 'whale-mini')
const IMAGE = path.join(DIR, 'chibi.png')
const CONFIG = path.join(DIR, 'config.json')
const STATE = path.join(DIR, 'state.json')
const WIDTH = 232
const HEIGHT = 96

const exists = (file) => access(file).then(() => true, () => false)

function reply(res, status, payload) {
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  })
  res.end(JSON.stringify(payload))
}

function loopback(req) {
  const address = req.socket.remoteAddress ?? ''
  return address === '::1' || address === '::ffff:127.0.0.1' || address.startsWith('127.')
}

/** 当前皮肤里那张 Q 版立绘（assets/*chibi*），没有就退回养的那只宠物的立绘。 */
async function pickSource() {
  let skin = null
  try {
    const state = JSON.parse(await readFile(path.join(HOME, 'skin-center-active.json'), 'utf8'))
    if (typeof state.active === 'string' && state.active !== '') skin = state.active
  } catch {
    // 没装皮肤就往下走
  }
  if (skin !== null) {
    const assets = path.join(HOME, 'skins', skin, 'assets')
    try {
      for (const name of await readdir(assets)) {
        if (/chibi/i.test(name) && /\.(webp|png|jpe?g)$/i.test(name)) return path.join(assets, name)
      }
    } catch {
      // 皮肤目录不在，退回宠物
    }
  }
  let petId = 'jyn'
  let petSkin = null
  try {
    const state = JSON.parse(await readFile(path.join(HOME, 'pet.json'), 'utf8'))
    if (typeof state.petId === 'string' && state.petId !== '') petId = state.petId
    if (state.skins !== null && typeof state.skins === 'object' && typeof state.skins[petId] === 'string') {
      petSkin = state.skins[petId]
    }
  } catch {
    // 没有 pet.json 就用默认那只
  }
  const previews = path.join(HOME, 'pets', petId, 'previews')
  const candidates = []
  if (petSkin !== null) candidates.push(path.join(previews, `${petSkin}-idle.webp`))
  candidates.push(path.join(previews, 'idle.webp'))
  for (const candidate of candidates) {
    if (await exists(candidate)) return candidate
  }
  return null
}

/** WebP 交给 NSImage 也能读，但 sips 转一次 PNG 最稳；源图变了就重转。 */
async function ensureImage() {
  const source = await pickSource()
  if (source === null) return null
  const from = await stat(source).catch(() => null)
  const cached = await stat(IMAGE).catch(() => null)
  if (cached !== null && from !== null && cached.mtimeMs >= from.mtimeMs) return IMAGE
  await mkdir(DIR, { recursive: true })
  await new Promise((resolve) => {
    const child = spawn('/usr/bin/sips', ['-s', 'format', 'png', source, '--out', IMAGE], { stdio: 'ignore' })
    child.on('exit', () => resolve())
    child.on('error', () => resolve())
  })
  return (await exists(IMAGE)) ? IMAGE : null
}

// ── 思考过程：agent/assistant-stream → state.json ───────────────────────────
const streams = new Map()
let published = { text: '', status: 'idle', at: 0 }
let flushTimer = null

function publish() {
  let latest = null
  for (const entry of streams.values()) {
    if (latest === null || entry.at > latest.at) latest = entry
  }
  if (latest === null) return
  published = { text: latest.text, status: latest.status, at: latest.at }
  if (flushTimer !== null) return
  flushTimer = setTimeout(() => {
    flushTimer = null
    const payload = JSON.stringify(published)
    mkdir(DIR, { recursive: true })
      .then(() => writeFile(`${STATE}.tmp`, payload))
      .then(() => rename(`${STATE}.tmp`, STATE))
      .catch(() => {})
  }, 200)
}

function note(sessionId, patch) {
  const previous = streams.get(sessionId) ?? { text: '', status: 'idle', at: 0 }
  streams.set(sessionId, { ...previous, ...patch, at: Date.now() })
  publish()
}

function trackStream({ agent, frame }) {
  const sessionId = agent?.session?.id
  if (typeof sessionId !== 'string') return
  if (frame?.type === 'start') {
    note(sessionId, { text: '', status: 'thinking' })
    return
  }
  if (frame?.type === 'end') {
    const previous = streams.get(sessionId)
    note(sessionId, { text: previous?.text ?? '', status: 'idle' })
    return
  }
  const chunk = frame?.chunk
  if (chunk === undefined) return
  const previous = streams.get(sessionId) ?? { text: '', status: 'idle', at: 0 }
  if (chunk.type === 'reasoning-delta') {
    note(sessionId, { text: (previous.text + chunk.text).slice(-800), status: 'thinking' })
  } else if (chunk.type === 'text-delta') {
    // 没有 reasoning 的模型：退回正文，至少能看到它在写什么
    const following = previous.status === 'thinking' ? previous.text : previous.text + chunk.text
    note(sessionId, { text: following.slice(-800), status: 'writing' })
  } else if (chunk.type === 'tool-call-delta') {
    note(sessionId, { text: previous.text, status: 'tool' })
  }
}

async function enter() {
  const image = await ensureImage()
  await mkdir(DIR, { recursive: true })
  const hide = process.env.WHALE_MINI_NO_HIDE !== '1'
  await writeFile(CONFIG, JSON.stringify({ image: image ?? '', width: WIDTH, height: HEIGHT, hide }, null, 2))
  // 交给 LaunchServices：已经在跑就复用（reopen 会重新亮出卡片），没跑就拉起。
  spawn('/usr/bin/open', ['-a', APP], { detached: true, stdio: 'ignore' }).unref()
}

export function apply(ctx) {
  ctx.on('agent/assistant-stream', trackStream, { global: true })

  ctx.inject(['webServer'], (scope) => {
    scope.effect(() => {
      const disposers = [
        scope.webServer.register({
          kind: 'exact',
          path: '/whale-mini/enter',
          handler: (req, res) => {
            if (!loopback(req)) return reply(res, 403, { ok: false, error: 'loopback only' })
            if (req.method !== 'POST') return reply(res, 405, { ok: false, error: 'POST only' })
            enter().then(
              () => reply(res, 200, { ok: true }),
              (error) => reply(res, 500, { ok: false, error: String(error?.message ?? error) }),
            )
          },
        }),
        scope.webServer.register({
          kind: 'exact',
          path: '/whale-mini/ping',
          handler: async (req, res) => {
            if (!loopback(req)) return reply(res, 403, { ok: false, error: 'loopback only' })
            const helper = await exists(APP)
            const image = await exists(IMAGE)
            reply(res, 200, { ok: true, helper, image, status: published.status })
          },
        }),
      ]
      return () => {
        for (const dispose of disposers) dispose()
      }
    }, 'whale-mini: routes')
  })
}
