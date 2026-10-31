# Fala remota (iPhone -> Mac fora de casa)

## O que o Fran tem de fazer (uma vez, 3 min)

1. Mac: abrir a app Tailscale, "Log in" (Google/Apple, conta à escolha).
2. iPhone: instalar Tailscale da App Store, entrar com a MESMA conta, ligar a VPN (pode ficar sempre ligada, "On Demand").
3. iPhone: Fala, menu ☰, "Ligar ao Mac": código e endereço (o nome `....ts.net`) que aparecem na aba iPhone do Mac. "Testar ligação" tem de dizer "Ligado a <Mac> via Tailscale · N ms".

## Como funciona (v2, 2026-10-15)

- **Caminhos**: Bonjour na rede local (3 s para ligar), depois o endereço guardado (MagicDNS `mac.tailXXXX.ts.net` ou `100.x.y.z`, porta 47800). Se a 47800 estiver ocupada, o Mac ouve noutra porta e o Bonjour anuncia-a.
- **Cifra ponta a ponta** (`Shared/LinkCrypto.swift`): chave = HKDF-SHA256(código de emparelhamento), ChaCha20-Poly1305 em cada pedido e resposta. Nada passa em claro, nem na rede local; mensagem adulterada ou código errado = recusada. O Tailscale (WireGuard) cifra outra vez por baixo.
- **Anti-replay**: cada pedido leva id aleatório de 16 bytes e hora; o Mac recusa mais de 10 min de diferença e ids já vistos. Um retry com o mesmo id recebe a resposta guardada: **repetir nunca cola duas vezes**.
- **Retries com backoff** (0,4 / 0,8 / 1,6 / 3,2 / 4 s) até ao prazo, em todos os caminhos; "ocupado" (Mac ainda a transcrever o mesmo pedido) espera e repete.
- **Fila offline** (`MacSender`, Documents/outbox): se o Mac não responder, o áudio fica guardado e sai sozinho quando a rede muda, a app volta ao ecrã ou de 20 em 20 s. Com menos de 90 s cola; mais antigo vai só para o histórico do Mac (não cola texto velho a meio de outra coisa). Descarta ao fim de 1 dia. O iPhone copia sempre o texto ao vivo para o clipboard.
- **Confirmação de entrega**: o Mac responde com o texto final (cifrado); só aí o item sai da fila.
- **Estado visível**: iPhone mostra "Ligado via rede local / Tailscale · N ms" (ping cifrado com latência); Mac mostra "Último contacto do iPhone há X via Tailscale/rede local" e quantos itens da fila entraram no histórico.
- **Áudio comprimido**: AAC 16 kHz mono 24 kbit/s, 12x menos que PCM (151 s: 4,7 MB -> 397 KB). Uma frase de 5 s são ~15 KB: passa em 3G.
- **Compatibilidade**: o Mac ainda aceita o protocolo v1 (código em claro, iPhones antigos). Quando os dois estiverem na v2, pode sair.
- **Enquadramento**: v2 leva tamanho no cabeçalho e não fecha o envio. Bug encontrado: na v1 o iPhone fechava o envio (half-close) e a resposta perdia-se no loopback; provável causa dos "<sem resposta>" do teste iPhone->Mac de manhã.

## Testes automáticos (sem iPhone)

`research/link-tests/run.sh` compila o código partilhado da app com um Mac falso e testa: cifra, código errado, adulteração, replay, mensagem velha, AAC, Mac desligado -> fila -> Mac volta -> entregue 1 vez, ping/latência, resposta perdida a meio (retry sem colar 2x), rede cai 1 s durante o envio, fila com 10 min (só histórico). 17/17 OK.
`.build/linktests e2e <porta> <wav>` (com `FALA_TOKEN`) fala com a app do Mac a sério em modo teste: joana_01 -> "Olá Fran, a reunião com a Zyra fica marcada para amanhã às 16h." (1,2 a 1,8 s com o modelo quente).

## Estado no Mac a 2026-10-15

O CLI `/opt/homebrew/bin/tailscale` não chega ao daemon (`/var/run/tailscaled.socket` não existe): falta o login na app Tailscale (passo 1).

## Alternativas grátis avaliadas

| Opção                                         | Configuração              | Contra                                                                                   |
| --------------------------------------------- | ------------------------- | ---------------------------------------------------------------------------------------- |
| **Tailscale** (escolhida)                     | App nos dois, mesma conta | Precisa de VPN ligada no iPhone                                                          |
| CloudKit / iCloud                             | Nenhuma para o utilizador | Exige conta Apple Developer paga com container CloudKit; não há                          |
| Port forwarding no router                     | Abrir porta 47800         | Expõe o Mac à internet, IP muda, CGNAT de muitas operadoras bloqueia                     |
| Relay próprio (Cloudflare Worker + WebSocket) | Deploy de um worker       | Áudio passa por servidor de terceiros; mais código; o plano grátis chega mas tem limites |
| ZeroTier                                      | Igual ao Tailscale        | Mesma ideia, app iOS menos polida                                                        |
| Cloudflare Tunnel (`cloudflared`)             | Túnel no Mac              | Endereço público: o código passa a ser a única defesa; precisa de domínio para nome fixo |
| Apple Continuity / Handoff                    | Nenhuma                   | Não há API pública para enviar dados arbitrários entre apps de outro programador         |

Conclusão: o Tailscale é a única opção grátis, privada e sem servidor.

### Fallback sem configuração (avaliado, não implementado)

Com a cifra v2, um relay já não vê o áudio (só bytes cifrados com a chave do código). Opção: Cloudflare Worker + Durable Object grátis, o Mac abre um WebSocket de saída e o iPhone envia para o mesmo "quarto" (id = hash do código). Prós: zero VPN, funciona em qualquer rede. Contras: precisa de conta Cloudflare e deploy (configuração do Fran, não zero), metadados (hora, tamanho) visíveis ao relay, limite grátis de pedidos, mais um sítio que pode falhar, e o código de 10 caracteres passa a ser a única defesa contra quem conheça o relay (força bruta offline sobre uma mensagem capturada: 31^10 ~ 8e14, aceitável com HKDF mas não ótimo; subir para 16 caracteres se avançar). Decisão: não implementar já; o Tailscale é mais simples e mais seguro. Se o Fran não quiser a VPN, este é o próximo passo, com o protocolo v2 tal como está.

## Relay em produção (2026-10-15, noite)

`relay/` (Cloudflare Worker + Durable Object, plano grátis, conta Cloudflare da Repz, worker separado `fala-relay`):
`https://fala-relay.fancy-bird-92d5.workers.dev`. O Mac mantém um WebSocket de saída (RelayLink, reabre sozinho);
o iPhone tenta rede local, Tailscale e por fim o relay (POST do pedido já cifrado). Sala = SHA256("fala-room-v1:"+código).
Chamadas de voz continuam só em ligação direta. Testes: `node relay/test.mjs` (relay), `research/relay-test` (iPhone falso
só pela internet contra a Fala real: ping 214 ms, 15 sessões, código errado recusado).
A Fala do Mac arranca no login e volta se cair: `~/Library/LaunchAgents/com.fran.fala.keepalive.plist`.
