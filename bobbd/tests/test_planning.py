import json
import time
from types import SimpleNamespace
import pytest
from test_agent import scripted, first_matching
from bobbd import planning, agent
from bobbd.generation import Generated

def generation(value):
    return Generated(json.dumps(value),1,1,1,False,"stop")

def test_missing_information_is_a_clarification_without_an_executable_plan(monkeypatch):
    monkeypatch.setattr(planning,"supports_generation",lambda e:True)
    monkeypatch.setattr(planning,"decide_many",scripted({"ready_to_act":False}))
    monkeypatch.setattr(planning,"stream_text",lambda *a,**kw:Generated("Per quale destinatario?",1,1,1,False,"stop"))
    result=planning.intake(object(),"Invia il documento")
    assert result.question=="Per quale destinatario?"
    assert result.url is None and not result.context

def test_a_generated_url_cannot_execute_javascript(monkeypatch):
    monkeypatch.setattr(planning,"supports_generation",lambda e:True)
    monkeypatch.setattr(planning,"decide_many",scripted({"ready_to_act":True,"grounded_intake":True}))
    monkeypatch.setattr(planning,"stream_text",lambda *a,**kw:generation({"start_url":"javascript:alert(1)"}))
    with pytest.raises(ValueError): planning.intake(object(),"Cerca sul sito")

@pytest.mark.parametrize("evidence", [[{"observation_id":"other","quote":"Documento salvato"}], [{"observation_id":"s1","quote":"Pagato 100 EUR"}], []])
def test_completion_cannot_use_unobserved_evidence(monkeypatch,evidence):
    monkeypatch.setattr(planning,"stream_text",lambda *a,**kw:generation({"complete":True,"report":"Fatto","evidence":evidence}))
    monkeypatch.setattr(planning,"decide_many",lambda *a,**kw:pytest.fail("Invalid evidence reached model verification"))
    assert planning.grounded_report(object(),"Salva",[{"id":"s1","text":"Documento salvato"}]) is None

def test_exact_quote_alone_does_not_prove_the_report_matches_the_goal(monkeypatch):
    monkeypatch.setattr(planning,"stream_text",lambda *a,**kw:generation({"complete":True,"report":"La riunione è prenotata","evidence":[{"observation_id":"s1","quote":"Bozza riunione"}]}))
    monkeypatch.setattr(planning,"decide_many",scripted({"verified_complete":False}))
    assert planning.grounded_report(object(),"Prenota la riunione",[{"id":"s1","text":"Bozza riunione"}]) is None

@pytest.mark.parametrize("operation,target",[("CLICK","invented"),("TYPE","e1"),("SHELL","e1")])
def test_ungrounded_actions_never_enter_the_closed_choice(monkeypatch,operation,target):
    obs={"id":"s1","screen_text":"Salva","candidates":[{"id":"e1","kind":"press","label":"Salva","role":"button"}],"apps":[],"keys":[]}
    monkeypatch.setattr(planning,"stream_text",lambda *a,**kw:generation({"next_goal":"Save","options":[{"operation":operation,"candidate_id":target}]}))
    def decisions(engine,context,questions,**kw):
        for q in questions:
            if q.name=="next_action": assert len(q.options)==3
        return scripted({"outcome_observed":False,"next_action":first_matching("No available action")})(engine,context,questions)
    monkeypatch.setattr(planning,"decide_many",decisions)
    verdict=planning.general_step(object(),agent.TaskSession("t","Salva",["Salva"]),obs,agent.candidates_by_kind(obs),started=time.perf_counter(),floor=.45)
    assert verdict.operation=="BLOCKED" and not verdict.candidate_id

def test_joint_choice_carries_the_validated_target_and_does_not_submit_text(monkeypatch):
    obs={"id":"s1","screen_text":"Search","candidates":[{"id":"e1","kind":"text","label":"Search","role":"search field"}],"apps":[],"keys":[]}
    monkeypatch.setattr(planning,"stream_text",lambda *a,**kw:generation({"next_goal":"Type","options":[{"operation":"TYPE","candidate_id":"e1"}]}))
    monkeypatch.setattr(planning,"decide_many",scripted({"outcome_observed":False,"next_action":first_matching("TYPE =")}))
    monkeypatch.setattr(agent,"write_text",lambda *a:"synthetic query")
    verdict=planning.general_step(object(),agent.TaskSession("t","Search",["Search"]),obs,agent.candidates_by_kind(obs),started=time.perf_counter(),floor=.45)
    assert (verdict.operation,verdict.candidate_id,verdict.text,verdict.submit)==("TYPE","e1","synthetic query",False)
