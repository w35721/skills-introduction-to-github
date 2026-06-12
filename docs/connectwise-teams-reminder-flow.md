# ConnectWise Unresponded-Ticket Reminder Flow (Power Automate → Microsoft Teams)

This flow checks ConnectWise Manage every 15 minutes for tickets that have not
received a response from the assigned engineer, and sends a Teams reminder
directly to the ticket owner. Because the check re-runs on a schedule and
re-evaluates every ticket each time, reminders automatically repeat every
15 minutes until a response is registered — no extra looping logic or state
storage is required.

---

## Choosing an approach (licensing)

Calling the ConnectWise REST API from Power Automate requires the **HTTP
action, which is a premium connector** (and the "When an HTTP request is
received" trigger is premium too, so ConnectWise can't call the flow
directly either). Pick based on what you have:

| | Approach | Cost | Looping behavior |
|---|---|---|---|
| **A** | ConnectWise workflow rule → email → standard Power Automate flow | $0 (standard connectors only) | Escalating reminders at fixed intervals (15/30/45/60 min), not infinite |
| **B** | Azure Logic Apps (Consumption) with the HTTP design below | ~$1–2/month pay-per-run | True every-15-min loop until response |
| **C** | Power Automate Premium with the HTTP design below | Premium per-user license | True every-15-min loop until response |

Options B and C use the identical design described in
[the API-polling design](#option-bc-api-polling-design-logic-apps-or-power-automate-premium) —
in Logic Apps the HTTP action is **built-in** (no premium licensing), and the
Microsoft Teams connector is available there as well. A 15-minute recurrence
is ~3,000 runs/month, which costs pennies on the Consumption plan. The only
prerequisite Logic Apps adds is an Azure subscription.

---

## Option A: No-premium design (ConnectWise workflow rule → email → Teams)

The trick is to split responsibilities: **ConnectWise detects the
unresponded ticket** (its workflow rules already know how to do this), and
**Power Automate only converts an email into a Teams DM** — which needs
nothing but standard connectors.

```
ConnectWise workflow rule
  (status in "New"/"Needs Response", age ≥ 15 min)
  └─ sends templated email to a shared mailbox
        └─ Power Automate: "When a new email arrives (V3)"  [standard]
             └─ parse ticket #, summary, owner email from the email
             └─ Teams: Post card in chat with the owner      [standard]
```

### 1. ConnectWise workflow rule

Setup Tables → **Workflow Rules** → new rule on your service board:

- **Conditions:** `Closed = No`, `Status` in your "awaiting response"
  statuses (e.g. New, New (email), Needs Response), owner not empty.
- **Events:** add one event per reminder interval — e.g. at 15, 30, 45 and
  60 minutes after the condition is met. Each event fires **once per
  ticket**, which is why this design gives a fixed escalation ladder rather
  than an infinite loop. (At the final event, consider notifying the
  service manager instead of the owner.)
- **Action:** Send email to your dedicated mailbox (e.g.
  `cw-reminders@yourdomain.com`) using an email template. Put structured,
  parseable content in it, for example:

  ```
  Subject: CW-REMINDER|[Ticket Number]|[Owner Email]
  Body:
  Summary: [Summary]
  Company: [Company Name]
  Entered: [Date Entered]
  ```

  (Use your CW version's template tokens; the exact token names vary.
  If a token for the owner's email isn't available, send the owner's
  identifier and map it to an email in the flow — see "Owner → Teams
  mapping" below.)

- When the engineer responds, board/workflow automation moves the ticket
  out of the qualifying status, the remaining events never fire, and the
  reminders stop — same self-terminating behavior as the API design.

### 2. Power Automate flow (all standard connectors)

1. **Trigger:** Office 365 Outlook — *When a new email arrives (V3)* on the
   shared mailbox, with Subject Filter `CW-REMINDER`.
2. **Parse the subject:**
   - Ticket #: `split(triggerOutputs()?['body/subject'], '|')[1]`
   - Owner email: `split(triggerOutputs()?['body/subject'], '|')[2]`
   - Pull summary/company out of the body the same way with `split()` on
     the line prefixes, or just include the email body text in the card.
3. **Teams — Post card in a chat or channel:** Post as Flow bot, in chat
   with the parsed owner email, using the same adaptive card shown in the
   API design below.
4. **(Optional)** Mark the email read / move it to an archive folder.

This costs nothing beyond licenses you already have, and the flow itself is
trivial — all the scheduling and "has anyone responded?" logic stays inside
ConnectWise where it's native.

---

## Option B/C: API-polling design (Logic Apps or Power Automate Premium)

## Prerequisites

1. **ConnectWise Manage API credentials**
   - An API Member in ConnectWise (System → Members → API Members) with access
     to the service boards you want to monitor.
   - A **public/private key pair** generated for that API member.
   - A **clientId** registered at https://developer.connectwise.com (required
     header on every API call).
2. **Either** an Azure subscription (Logic Apps Consumption — the HTTP
   action there is built-in, no premium licensing) **or** a Power Automate
   Premium license (the HTTP action in Power Automate is a premium
   connector).
3. **Microsoft Teams connector** (standard) — engineers must be reachable by
   their ConnectWise `officeEmail`, which should match their Microsoft 365 UPN.
   If the addresses differ, add a mapping table (see "Owner → Teams mapping").

## Authentication header

ConnectWise uses Basic auth with a composite username:

```
Authorization: Basic base64( companyId + "+" + publicKey : privateKey )
clientId: <your-registered-client-id>
Accept: application/json
```

Build the base64 value once in a Compose action, or store the whole header
value in an environment variable / Azure Key Vault.

---

## Flow design

```
Recurrence (every 15 min)
  └─ Compose: cutoff time = utcNow() - 15 minutes
  └─ HTTP: GET unresponded tickets from ConnectWise
  └─ Parse JSON
  └─ Apply to each (ticket)
       └─ HTTP: GET owner member record  → officeEmail
       └─ Teams: Post adaptive card in chat with the engineer
```

### 1. Trigger — Recurrence

- Interval: `15`, Frequency: `Minute`.

### 2. Compose — cutoff timestamp

Expression:

```
addMinutes(utcNow(), -15)
```

ConnectWise condition syntax expects timestamps in square brackets,
e.g. `[2026-06-12T18:00:00Z]`. Format it with:

```
concat('[', formatDateTime(addMinutes(utcNow(), -15), 'yyyy-MM-ddTHH:mm:ssZ'), ']')
```

### 3. HTTP — query tickets awaiting a response

```
GET https://<your-site>/v4_6_release/apis/3.0/service/tickets
```

Query parameters (URL-encode the `conditions` value):

```
conditions=closedFlag = false
  and board/name = "<Your Service Board>"
  and status/name in ("New", "New (email)", "Needs Response")
  and dateEntered < <output of step 2>
pageSize=100
fields=id,summary,dateEntered,owner/id,owner/identifier,status/name,company/name
```

Two ways to define "not responded":

- **Status-based (recommended).** Most service boards move a ticket out of
  "New"/"Needs Response" the moment an engineer adds a note or time entry
  (via workflow rules or board automation). Filtering on those statuses plus
  `dateEntered` older than 15 minutes is one API call and is reliable.
  The reminder stops on its own because a responded ticket no longer matches
  the query.
- **Note-based (alternative).** If your statuses don't reflect responses,
  query candidate tickets first, then for each ticket call
  `GET /service/tickets/{id}/allNotes` and treat the ticket as "responded"
  when any note has a non-null `member` (i.e., written by an internal
  engineer rather than the contact). For "responded since the customer's
  last message", compare the newest member note date against the newest
  contact note date. This costs one extra API call per ticket.

> If a ticket has no owner, `owner` is null. Add a Condition inside the loop
> to skip (or route to a team channel instead) when
> `empty(items('Apply_to_each')?['owner'])` is true.

### 4. Parse JSON

Use a sample response from step 3 to generate the schema. The fields you need:
`id`, `summary`, `dateEntered`, `company.name`, `owner.id`, `owner.identifier`.

### 5. Apply to each ticket

**5a. HTTP — resolve the owner's email**

```
GET https://<your-site>/v4_6_release/apis/3.0/system/members/{owner.id}?fields=officeEmail,firstName
```

(Or pre-load all members once per run before the loop and use a Filter array
action inside the loop — fewer API calls if you have many open tickets.)

**5b. Teams — "Post card in a chat or channel"**

- Post as: **Flow bot**
- Post in: **Chat with Flow bot**
- Recipient: `officeEmail` from 5a

Adaptive card body:

```json
{
  "type": "AdaptiveCard",
  "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
  "version": "1.4",
  "body": [
    {
      "type": "TextBlock",
      "text": "⏰ Ticket awaiting your response",
      "weight": "Bolder",
      "size": "Medium"
    },
    {
      "type": "FactSet",
      "facts": [
        { "title": "Ticket", "value": "#@{items('Apply_to_each')?['id']}" },
        { "title": "Summary", "value": "@{items('Apply_to_each')?['summary']}" },
        { "title": "Company", "value": "@{items('Apply_to_each')?['company']?['name']}" },
        { "title": "Created", "value": "@{formatDateTime(items('Apply_to_each')?['dateEntered'], 'g')}" }
      ]
    },
    {
      "type": "TextBlock",
      "text": "This reminder repeats every 15 minutes until a response is logged on the ticket.",
      "isSubtle": true,
      "wrap": true
    }
  ],
  "actions": [
    {
      "type": "Action.OpenUrl",
      "title": "Open ticket",
      "url": "https://<your-site>/v4_6_release/services/system_io/Service/fv_sr100_request.rails?service_recid=@{items('Apply_to_each')?['id']}"
    }
  ]
}
```

---

## How the 15-minute loop terminates

There is intentionally **no stored state**. Each run re-queries ConnectWise:

- Ticket still matches (no response logged / status unchanged) → owner gets
  another reminder.
- Engineer responds → status changes (or a member note now exists) → ticket
  drops out of the query → reminders stop.

## Owner → Teams mapping

If ConnectWise `officeEmail` doesn't match the engineer's Microsoft 365 sign-in
address, keep a small mapping (SharePoint list or an `Object` variable like
`{"jsmith": "john.smith@yourdomain.com"}`) and look up the Teams address by
`owner.identifier` before step 5b.

## Optional enhancements

- **Escalation:** count reminders per ticket in a SharePoint list; after N
  reminders, also post to a team channel or notify the service manager.
- **Business hours:** wrap the query/loop in a Condition on
  `dayOfWeek(utcNow())` and hour so engineers aren't pinged overnight.
- **Error handling:** add a parallel "has failed" branch on the HTTP action
  that posts to an ops channel, and set Retry Policy to exponential.
- **Throttling:** ConnectWise allows ~1,000 requests/min per clientId, but if
  you monitor many boards, prefer the "pre-load members once per run" pattern.
