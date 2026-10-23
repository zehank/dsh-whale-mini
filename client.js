/**
 * whale-mini / client —— 两个入口：会话标题栏的一个小按钮 + 命令菜单里的「缩成鲸鱼娘」。
 *
 * 都只做一件事：POST /whale-mini/enter，宿主拉起原生卡片（Q 版鲸鱼娘 + 实时思考文字）。
 * 不 import 任何 @deepseek-ai/*；只用框架注入的 slots / commandUi。
 */
window.__ModuleLoader__.load({
  id: '@local/whale-mini',
  factory(require) {
    const React = require('react')
    const h = React.createElement

    const enter = () => {
      fetch('/whale-mini/enter', { method: 'POST' }).catch((error) => {
        console.warn('[whale-mini] 收不起来：', error)
      })
    }

    /** 标题栏那枚小按钮：平时是灰的，悬停亮一点。 */
    function WhaleButton() {
      const [hover, setHover] = React.useState(false)
      return h('button', {
        type: 'button',
        title: '缩成鲸鱼娘：整个窗口收起，桌面留一张置顶小卡片，点卡片回来',
        onClick: enter,
        onMouseEnter: () => setHover(true),
        onMouseLeave: () => setHover(false),
        style: {
          display: 'inline-flex',
          alignItems: 'center',
          gap: 4,
          height: 24,
          padding: '0 8px',
          borderRadius: 6,
          border: '1px solid var(--dsw-alias-border-l2)',
          background: hover ? 'var(--dsw-alias-interactive-bg-hover)' : 'transparent',
          color: 'var(--dsw-alias-label-secondary)',
          font: 'inherit',
          fontSize: 12,
          lineHeight: 1,
          cursor: 'pointer',
        },
      }, '🐋', h('span', null, '收起'))
    }

    return {
      inject: ['slots', 'commandUi'],
      apply(ctx) {
        ctx.effect(() => ctx.commandUi.register({
          name: 'whale',
          label: () => '缩成鲸鱼娘',
          description: () => '整个窗口收起来，桌面留一张置顶小卡片（Q 版 + 实时思考），点它回到窗口',
          available: () => true,
          ui: { kind: 'action', run: enter },
        }), 'whale-mini: /whale 命令')

        ctx.effect(() => ctx.slots.inject('conversation.session.header.actions', () => ctx.slots.register({
          name: 'conversation.session.header.actions',
          id: 'whale-mini',
          order: 30,
        }, WhaleButton)), 'whale-mini: header button')
      },
    }
  },
})
