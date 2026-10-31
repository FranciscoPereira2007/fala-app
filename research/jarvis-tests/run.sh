#!/bin/zsh
# Testes do Jarvis sem iPhone: o mesmo código da app (Shared + Mac/Jarvis) com um Mac falso em loopback.
# Uso: ./run.sh                      (unitários + protocolo + lista real de sessões)
#      ./run.sh <sessionId> [wav]     (+ envia prompt e faz uma chamada a essa sessão; usa SÓ numa sessão de teste)
cd "${0:A:h}"; S=../../Shared; M=../../Mac/Jarvis; mkdir -p .build
swiftc -O -parse-as-library -o .build/jarvistests main.swift ../link-tests/BenchLoad.swift $S/Link.swift $S/LinkCrypto.swift $S/AudioCodec.swift $S/MacSender.swift $S/FalaGroup.swift $S/Jarvis.swift $S/CallClient.swift $M/SessionHub.swift $M/Voice.swift $S/PCNode.swift $S/RelayTunnel.swift ../../Mac/AIAccounts.swift ../../Mac/JarvisAgent.swift ../../Mac/JarvisAPI.swift $M/CallServer.swift $M/VoiceFront.swift ../../Mac/RemoteInput.swift 2>&1 | grep -E "^[^ ]*: error:" && { echo "FALHA: não compilou"; exit 1; }
.build/jarvistests "$@"
