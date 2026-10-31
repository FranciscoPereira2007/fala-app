# Protocolo Fala Link (Mac, iPhone, Windows)

Estado: v2 implementado (Mac servidor, iPhone cliente); Jarvis (J, C) implementado a 2026-10-15. Grupo de dispositivos (secção 6) é o desenho para quando entrar o Windows: ainda não implementado.

Objetivo: qualquer pessoa instala a Fala e emparelha os SEUS dispositivos (Mac, iPhone, PC). Sem servidor nosso, sem conta online, nada de nomes fixos no código. Tudo o que está aqui é implementável em Swift, C#/.NET ou Python com bibliotecas padrão (TCP, mDNS, HKDF-SHA256, ChaCha20-Poly1305).

## 1. Transporte e descoberta

- TCP. Porta preferida 47800; se estiver ocupada, porta livre anunciada no mDNS.
- Rede local: mDNS/DNS-SD, serviço `_fala._tcp` (Bonjour no Mac/iOS; no Windows: `Windows.Networking.ServiceDiscovery.Dnssd` ou a API DnsServiceRegister/DnsServiceBrowse do Win10+).
- Remoto: endereço manual `host[:porta]`. Recomendado: Tailscale grátis do próprio utilizador (MagicDNS `nome.tailXXXX.ts.net` ou `100.x.y.z`). Qualquer VPN/IP serve: a segurança não depende da rede.
- Um pedido = uma ligação, exceto chamadas (secção 5), que mantêm a ligação aberta.

## 2. Cifra (v2)

- Chave do par: `K = HKDF-SHA256(ikm = UTF8(maiúsculas(código)), salt = "fala-link-v2", info = "iphone-mac", 32 bytes)`.
- Pedido no fio: `"F2"` + `UInt32 BE` tamanho + `nonce(12) + cifra + tag(16)` (ChaCha20-Poly1305, formato "combined" da CryptoKit).
- Claro do pedido: `id(16 aleatórios) + hora (Int64 BE, ms desde 1970) + corpo`.
- Resposta: mesmo enquadramento, claro = `id do pedido + corpo`. O cliente recusa respostas com outro id.
- Anti-replay (servidor): recusa |hora - agora| > 10 min; guarda ids vistos 20 min; id repetido devolve a resposta guardada (retry seguro, nunca executa 2 vezes). Ainda em processamento: responde `"B"` (repetir depois).
- Código errado ou mensagem adulterada: resposta `"N"` em claro (sem enquadramento).
- v1 (legado, só iPhones antigos): `"K" + código + "\n" + corpo`, em claro. A remover quando todos estiverem na v2.

## 3. Corpos (primeiro byte = tipo)

| Corpo                                   | Pedido                                                                                            | Resposta                                                    |
| --------------------------------------- | ------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| `P`                                     | ping                                                                                              | `P` + nome do dispositivo                                   |
| `PJ`                                    | ping com capacidades                                                                              | `P` + nome + `\n` + capacidades, uma por linha (`jarvis=1`) |
| `0`/`1` + texto                         | colar texto (1 = Enter depois)                                                                    | `ok`                                                        |
| `A`/`a`/`H` + `0`/`1` + `C`/`R` + áudio | ditado: A cola, a só transcreve, H só histórico; C = AAC m4a 16 kHz mono, R = PCM Int16 LE 16 kHz | `T` + texto, ou `E`                                         |
| `J` + JSON                              | Jarvis (secção 4)                                                                                 | `J` + JSON                                                  |
| `C` + JSON                              | abrir chamada (secção 5)                                                                          | `C` + nonce(16), ligação fica aberta                        |

Regra de compatibilidade: um cliente só usa um tipo novo depois de o ver anunciado em `PJ`. Um servidor antigo trata tipos desconhecidos como texto (colava-o), por isso nunca se envia `J`/`C` às cegas. Capacidades novas = linha nova em `PJ`, nunca mudar o significado de uma existente.

## 4. Jarvis (JSON, datas em ms desde 1970)

Pedido `{"op": ..., "id"?, "text"?, "limit"?, "since"?}`:

- `list` -> `{"ok", "sessions": [Session], "lastEvent"}`
- `tail` (`id`, `limit`) -> `{"ok", "messages": [{"id","role":"user|agent","text","at"}]}`
- `send` (`id`, `text`) -> `{"ok"}` ou `{"ok": false, "error"}`
- `events` (`since`) -> `{"ok", "events": [{"id","kind":"finished|needsYou","sessionID","sessionName","summary","at"}], "lastEvent"}`

`Session = {"id","kind":"claude|codex","name","cwd","status":"busy|idle|outro","updatedAt","pid"?,"lastReply"?,"canSend"}`. Campos desconhecidos devem ser ignorados (evolução sem partir clientes).

## 5. Chamada (áudio full-duplex)

1. Cliente envia pedido v2 com `C{"session": id}`. Servidor responde (cifrado) `C + nonce(16)` e não fecha.
2. Chave da chamada: `Kc = HKDF-SHA256(ikm = K, salt = id do pedido + nonce, info = "fala-call-v1", 32)`.
3. Frames nos dois sentidos: `"F2" + UInt32 BE + ChaChaPoly(Kc, dir(1) + seq(UInt64 BE) + tipo(1) + dados)`.
   - `dir`: `U` (0x55) cliente->servidor, `D` (0x44) servidor->cliente. Frame com a direção errada = fim (anti-reflexão).
   - `seq` começa em 1 e sobe sempre por direção; repetido ou a descer = fim (anti-replay).
   - Tipos: `a` microfone PCM Int16 LE 16 kHz mono (blocos de 20 a 100 ms); `o` voz PCM Int16 LE à taxa `ttsRate`; `t` evento JSON `{"state","text"?,"ttsRate"?}` (states: ready, listening, heard, thinking, speaking, error); `x` parar a voz já (barge-in); `h` desligar.
4. O servidor decide as vezes (VAD por energia, fim de vez com 0,7 s de silêncio), transcreve, injeta, resume e fala. O cliente só toca e envia (deve usar cancelamento de eco do sistema).

## 6. Grupo de dispositivos ("conta local", desenho para a v3)

- Cada dispositivo gera na 1.ª abertura `deviceId` (UUID) e um par de chaves X25519; nome = nome do sistema, editável. Nada fixo no código.
- Grupo = lista de dispositivos de confiança guardada em cada um (Keychain / DPAPI no Windows). Sem servidor.
- Emparelhar: um dispositivo já no grupo mostra um código de 10 caracteres e um QR `fala://pair?c=<código>&h=<host:porta>&id=<deviceId>`. O novo dispositivo lê o QR (ou escreve o código), liga com a cifra v2 (a chave vem do código), e os dois trocam `{deviceId, nome, chave pública X25519, plataforma, capacidades}`. A partir daí cada par usa `HKDF(X25519(a, B))` em vez do código; o código expira (10 min ou 1 uso).
- Revogar: remover o deviceId do grupo em qualquer dispositivo propaga no próximo contacto (lista assinada com versão crescente).
- Papéis por capacidade, não por plataforma: `stt` (tem Whisper), `paste` (cola no ecrã), `jarvis` (vê sessões de agentes), `tts`. Um PC Windows com GPU pode anunciar `stt`, `tts` e `jarvis`; o iPhone é sobretudo cliente.
- Versões: `PJ` passa a devolver também `proto=3`, `id=<deviceId>`. Um dispositivo v3 fala v2 com quem só anuncia v2.
- Remoto: cada utilizador usa o seu Tailscale (ou outro); o endereço fica guardado por dispositivo do grupo.
