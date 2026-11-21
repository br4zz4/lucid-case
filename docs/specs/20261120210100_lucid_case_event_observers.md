---
title: lucid-case — observadores síncronos do evento de caso
status: proposed
created: 2026-11-20
updated: 2026-11-21
owner: "@oporpino"
certainty: high
---

# lucid-case — observadores síncronos do evento de caso

> **TLDR**: adicionar `config.events.observers`: objetos chamados no mesmo ponto e na mesma transação em que o Command produz seu evento de caso (sucesso dentro da transação, falha depois do rollback), com o Command e o resultado em mãos, independentes de `recording` e do `store`, para que outra gem (o `lucid-backoffice`) grave um registro próprio com a mesma garantia "existe se e só se o dado existe".

Spec 2 da sequência backoffice (ADR `docs/adr/0007-backoffice-as-standalone-gem-with-adapters.md`). Repo: `br4zz4/lucid-case` (`~/workspace/br4zz4/lucid-case`). Copiada para `docs/specs/` do repo no primeiro PR.

Nome: `observers`, não `recorders`, porque `Lucid::Case::Events::Recorder` já existe (captura de testes).

# what

Como autor de uma gem que precisa registrar cada Command (trilha de auditoria), quero ser avisado de forma síncrona e transacional quando um Command termina, recebendo o Command e o resultado crus, para gravar meu registro na mesma transação sem depender do outbox, de jobs nem de `recording :enabled`.

## out of scope

- Observar Queries e Subscribers (eles não produzem evento de caso).
- Mudar o formato do evento, do outbox ou da entrega.
- Observers assíncronos (para isso existem os subscribers).

## acceptance criteria

    Cenário: sucesso chama o observer dentro da transação
      Dado um observer registrado em config.events.observers
      Quando Enrollment::Approve termina com success
      Então o observer recebe (event:, command:, result:) antes do commit, com result.success? true
      E event.name é "enrollment.approve" e command é a instância (attributes e result.content com os records originais)

    Cenário: falha tipada chama o observer depois do rollback
      Quando o Command termina com failure(:last_owner)
      Então o observer recebe o resultado com type :last_owner depois do rollback, fora da transação do case

    Cenário: guard e validação também notificam
      Quando o Command para num `fail_if :last_owner?`, num `fail_with(:x)` ou em `validates` (`:invalid_attributes`)
      Então o observer recebe o resultado com esse type e `result[:errors]` com a mensagem, depois do rollback, como no evento de caso

    Cenário: exceção não chama observer
      Quando o Command levanta erro
      Então nenhum observer é chamado

    Cenário: independente de recording e store
      Dado config.events.recording :disabled (ou store :inline, ou :outbox)
      Quando o Command termina com sucesso
      Então o observer é chamado do mesmo jeito

    Cenário: events :disabled no Command desliga também os observers
      Dado um Command com `events :disabled`
      Então nenhum observer é chamado para ele

    Cenário: observer que levanta desfaz o Command (falha fechada)
      Dado um observer que levanta erro no sucesso de um Command transacional
      Então a transação do Command faz rollback e o erro propaga

    Cenário: Command com transaction :disabled
      Então o observer é chamado depois do sucesso, sem transação, e um erro dele propaga sem desfazer o que já foi gravado

    Cenário: emit e steps
      Quando o Command chama emit(:x) ou conclui um step
      Então o observer recebe também esses eventos (kind :custom e :step), no mesmo momento em que seriam gravados

    Cenário: configuração inválida
      Quando adiciono a observers algo que não responde a call(event:, command:, result:)
      Então validate! levanta ArgumentError no boot

# why

O `lucid-backoffice` precisa de uma trilha de 6 meses de quem fez o quê. O outbox do `lucid-case` não serve como trilha (retenção de dias, `inline` é no máximo uma vez, depende de `recording`), e um subscriber gravaria depois, num job. Um observer síncrono no ponto onde o evento nasce dá a garantia transacional sem que a gem de backoffice conheça internals do `lucid-case`, e serve a qualquer outra integração (métricas, auditoria própria).

# how

Regras: TDD, minitest contra PostgreSQL real como o resto da gem, YARD no que é público, docs em inglês, sem comentários explicativos.

**Feature flag:** não. Lista vazia por padrão: comportamento atual intacto.

**Telas:** sem telas. **Staging:** `staging: none`.

## Desenho

- `Lucid::Case::Events::Configuration#observers` (Array, padrão `[]`); `validate!` exige `respond_to?(:call)`.
- `Lucid::Case::Events::Observation.notify(event:, command:, result:)` chamado em `lucid_record_case_event`, `lucid_record_step_event` e `emit`, **antes** do `return unless events_recording?`, respeitando só `events_setting == :disabled`. O evento é montado com o mesmo `lucid_build_event` (id, nome, tipo, context), sem round trip de serialização quando o outbox está desligado.
- O momento é o mesmo do evento de caso: sucesso dentro da transação do case; falha depois do rollback.

## PR 1 — observers (branch: `feat/event-observers-1`, base: `main`)
**Arquivos:** Create `lib/lucid/case/events/observation.rb` — Modify `lib/lucid/case/events.rb`, `lib/lucid/case/events/configuration.rb` — Test `test/lucid/case/events/observers_test.rb` (novo), `test/lucid/case/events/configuration_test.rb` (existente: `validate!`) — Docs: `docs/specs/20261120210100_lucid_case_event_observers.md` (cópia)
**Passos:** testes de todos os cenários → implementação → commit `feat: add synchronous event observers`
**Pronto para prod:** sem observer configurado nada muda.
**Valida:** `bundle exec rake test`

## PR 2 — docs e release (branch: `feat/event-observers-2`, base: `feat/event-observers-1`)
**Arquivos:** Modify `docs/events.md` (seção "Observers"), `docs/configuration.md`, `CHANGELOG.md` (seção `## 0.4.0` com "Upgrading from 0.3.1"), `lib/lucid/case/version.rb` (0.3.1 → 0.4.0), `test/lucid/case/version_test.rb`
**Passos:** docs → tag `v0.4.0` → commit `docs: document event observers`
**Valida:** `bundle exec rake test`

## SEQUENCE
1. #<pr1> — observers
2. #<pr2> — docs e release
Merge in this order: #<pr1> #<pr2>

# definition of done

- [ ] Todo cenário de "acceptance criteria" foi validado (automatizado ou verificado com comando exato)
- [ ] Testes automáticos passando — suíte verde, não só a parte nova (`bundle exec rake test`)
- [ ] Toda task do "how" executada
- [ ] Documentação atualizada (`docs/events.md`, `docs/configuration.md`, `CHANGELOG.md`)
- [ ] Staging: `staging: none` (gem)
- [ ] Cada PR da sequência validado isoladamente (build e testes verdes sem os PRs seguintes)
- [ ] Último PR liga a funcionalidade e remove código temporário (tag `v0.4.0` publicada)
- [ ] Sucesso dentro da transação, falha após rollback, exceção sem chamada (`test/lucid/case/events/observers_test.rb`)
- [ ] Guard (`fail_if`/`fail_with`) e `validates` notificam com o type e `errors` (mesmo teste)
- [ ] Independente de recording/store; `events :disabled` desliga (mesmo teste)
- [ ] Observer que levanta desfaz o Command transacional; com `transaction :disabled` propaga sem desfazer (mesmo teste)
- [ ] emit e step notificados (mesmo teste)
- [ ] Observer inválido falha no `validate!` (mesmo teste)

## documentation

- `docs/events.md` e `docs/configuration.md` da gem: observers (quando usar observer vs subscriber).
- `CHANGELOG.md` da gem.
